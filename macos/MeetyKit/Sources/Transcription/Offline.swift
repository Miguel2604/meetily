import AVFoundation
import Core
import Foundation

public enum ImportError: Error, Equatable, CustomStringConvertible {
    case unsupported(String)
    case noAudioTrack
    case noAudio
    case meetingNotFound(String)

    public var description: String {
        switch self {
        case .unsupported(let ext): "Unsupported format: .\(ext). Supported: \(OfflineTranscription.extensions.joined(separator: ", "))"
        case .noAudioTrack: "The file has no audio track"
        case .noAudio: "No audio file found in the meeting folder"
        case .meetingNotFound(let id): "Meeting \(id) not found"
        }
    }
}

/// Decodes any file AVFoundation reads to 16 kHz mono float, reporting the fraction decoded.
public func decodeAudio(_ url: URL, progress: @Sendable (Double) -> Void = { _ in }) async throws -> [Float] {
    let asset = AVURLAsset(url: url)
    guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw ImportError.noAudioTrack }
    let duration = try await asset.load(.duration).seconds
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: transcriptionSampleRate, AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
    ])
    reader.add(output)
    guard reader.startReading() else { throw reader.error ?? ImportError.noAudioTrack }
    var samples: [Float] = []
    if duration.isFinite { samples.reserveCapacity(Int(duration * transcriptionSampleRate)) }
    while let buffer = output.copyNextSampleBuffer() {
        try Task.checkCancellation()
        guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
        let count = CMBlockBufferGetDataLength(block) / MemoryLayout<Float>.size
        let start = samples.count
        samples += repeatElement(0, count: count)
        _ = samples.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count * 4, destination: $0.baseAddress! + start * 4) }
        if duration > 0 { progress(min(0.99, CMSampleBufferGetPresentationTimeStamp(buffer).seconds / duration)) }
    }
    if reader.status == .failed { throw reader.error ?? ImportError.noAudioTrack }
    progress(1)
    return samples
}

/// Import and retranscription: decode → batch VAD → ASR, the `import.rs` / `retranscription.rs` flow.
public enum OfflineTranscription {
    /// shortcut: what AVFoundation decodes; ogg/webm/mkv/wma need a decoder, add one when a file needs it.
    public static let extensions = ["mp3", "m4a", "aac", "wav", "flac", "caf", "mp4", "aiff"]

    public enum Stage: String, Sendable { case copying, decoding, detecting, transcribing, saving, complete }

    public struct Progress: Sendable {
        public var stage: Stage
        /// Overall, 0...1.
        public var fraction: Double
    }

    public struct ImportResult: Sendable {
        public var meetingID: String
        public var title: String
        public var segmentCount: Int
        public var duration: Double
    }

    public static func validate(_ url: URL) throws {
        let ext = url.pathExtension.lowercased()
        guard extensions.contains(ext) else { throw ImportError.unsupported(ext) }
    }

    /// Copies `source` into a new meeting folder, transcribes it and creates the meeting.
    /// Cancelling (or failing) before the meeting is saved removes the folder.
    public static func importAudio(
        _ source: URL, title: String, recordingsFolder: URL, store: Store, engine: any TranscriptionEngine,
        detector: any VoiceDetector, progress: @escaping @Sendable (Progress) -> Void = { _ in }
    ) async throws -> ImportResult {
        try validate(source)
        progress(Progress(stage: .copying, fraction: 0))
        let folder = try createFolder(Paths.meetingFolder(base: recordingsFolder, name: title))
        let audioFile = "audio.\(source.pathExtension.lowercased())"
        let segments: [NewSegment]
        let duration: Double
        do {
            try FileManager.default.copyItem(at: source, to: folder.appending(path: audioFile))
            (segments, duration) = try await transcribe(folder.appending(path: audioFile), engine: engine, detector: detector, progress: progress)
            try Task.checkCancellation()
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        progress(Progress(stage: .saving, fraction: 0.85))
        let id = try await store.saveMeeting(title: title, segments: segments, folderPath: folder.path)
        try writeTranscripts(segments, to: folder)
        let now = Timestamp.now()
        try MeetingMetadata.update(in: folder) { _ in [
            "version": "1.0", "meeting_id": id, "meeting_name": title, "created_at": now, "completed_at": now,
            "duration_seconds": duration, "audio_file": audioFile, "transcript_file": "transcripts.json",
            "status": "completed", "source": "import",
        ] }
        progress(Progress(stage: .complete, fraction: 1))
        return ImportResult(meetingID: id, title: title, segmentCount: segments.count, duration: duration)
    }

    /// Transcribes a meeting's audio again (another model or language) and swaps its transcript in one
    /// transaction. Cancelling leaves the old transcript. Returns the new segment count.
    public static func retranscribe(
        meetingID: String, store: Store, engine: any TranscriptionEngine, detector: any VoiceDetector,
        progress: @escaping @Sendable (Progress) -> Void = { _ in }
    ) async throws -> Int {
        guard let meeting = try await store.meeting(id: meetingID) else { throw ImportError.meetingNotFound(meetingID) }
        guard let path = meeting.folderPath, let audio = findAudio(in: URL(fileURLWithPath: path, isDirectory: true)) else {
            throw ImportError.noAudio
        }
        let (segments, duration) = try await transcribe(audio, engine: engine, detector: detector, progress: progress)
        try Task.checkCancellation()
        progress(Progress(stage: .saving, fraction: 0.85))
        try await store.replaceTranscripts(meetingID: meetingID, segments: segments)
        let folder = audio.deletingLastPathComponent()
        try writeTranscripts(segments, to: folder)
        let now = Timestamp.now()
        try MeetingMetadata.update(in: folder) { existing in
            var metadata = existing ?? [
                "version": "1.0", "meeting_id": meetingID, "created_at": now, "completed_at": now,
                "audio_file": audio.lastPathComponent, "source": "retranscription",
            ]
            metadata.merge(["duration_seconds": duration, "retranscribed_at": now, "status": "completed",
                            "transcript_file": "transcripts.json"]) { $1 }
            metadata["detected_summary_language"] = nil
            return metadata
        }
        progress(Progress(stage: .complete, fraction: 1))
        return segments.count
    }

    /// Creates `folder`, or `folder (2)`, `(3)`… when it exists, so a failed import only removes its own folder.
    static func createFolder(_ folder: URL) throws -> URL {
        try FileManager.default.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
        for n in 1... {
            let candidate = n == 1 ? folder : folder.deletingLastPathComponent().appending(path: "\(folder.lastPathComponent) (\(n))", directoryHint: .isDirectory)
            do {
                try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: false)
                return candidate
            } catch CocoaError.fileWriteFileExists {}
        }
        fatalError("unreachable")
    }

    /// The recording in a meeting folder, by the names the Tauri app used, then any decodable file.
    public static func findAudio(in folder: URL) -> URL? {
        let names = ["audio.mp4", "audio.m4a", "audio.wav", "audio.mp3", "audio.flac", "recording.mp4"]
        if let name = names.first(where: { FileManager.default.fileExists(atPath: folder.appending(path: $0).path) }) {
            return folder.appending(path: name)
        }
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.sorted { $0.path < $1.path }.first { extensions.contains($0.pathExtension.lowercased()) }
    }

    /// decode 0–20 %, VAD 20–30 %, ASR 30–85 %.
    static func transcribe(
        _ url: URL, engine: any TranscriptionEngine, detector: any VoiceDetector, progress: @escaping @Sendable (Progress) -> Void
    ) async throws -> ([NewSegment], Double) {
        let samples = try await decodeAudio(url) { progress(Progress(stage: .decoding, fraction: $0 * 0.2)) }
        let duration = Double(samples.count) / transcriptionSampleRate
        var segmenter = SpeechSegmenter(detector: detector, config: .batch)
        var chunks: [SpeechChunk] = []
        let step = Int(transcriptionSampleRate) * 10
        for start in stride(from: 0, to: samples.count, by: step) {
            try Task.checkCancellation()
            chunks += try await segmenter.process(Array(samples[start..<min(start + step, samples.count)]))
            progress(Progress(stage: .detecting, fraction: 0.2 + 0.1 * Double(min(start + step, samples.count)) / Double(samples.count)))
        }
        chunks += try await segmenter.flush()
        var segments: [NewSegment] = []
        for (index, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            for piece in try await engine.transcribe(samples: chunk.samples) {
                let text = piece.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                segments.append(NewSegment(text: text, timestamp: Timestamp.now(),
                                           audioStartTime: chunk.start + piece.start, audioEndTime: chunk.start + piece.end))
            }
            progress(Progress(stage: .transcribing, fraction: min(0.85, 0.3 + 0.55 * Double(index + 1) / Double(chunks.count))))
        }
        return (segments, duration)
    }

    /// `transcripts.json` in the `write_transcripts_json` layout.
    static func writeTranscripts(_ segments: [NewSegment], to folder: URL) throws {
        let json: [String: Any] = [
            "version": "1.0", "last_updated": Timestamp.now(), "total_segments": segments.count,
            "segments": segments.enumerated().map { index, s in [
                "id": "transcript-\(UUID().uuidString.lowercased())", "text": s.text, "timestamp": s.timestamp,
                "audio_start_time": s.audioStartTime, "audio_end_time": s.audioEndTime,
                "duration": s.audioEndTime - s.audioStartTime, "sequence_id": index,
            ] as [String: Any] },
        ]
        try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
            .write(to: folder.appending(path: "transcripts.json"), options: .atomic)
    }
}
