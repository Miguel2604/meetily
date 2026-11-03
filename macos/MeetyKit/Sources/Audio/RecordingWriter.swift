import AVFoundation
import Core
import Foundation

/// Writes a meeting folder the way `recording_saver.rs` laid it out: `audio.mp4` (AAC, 48 kHz mono),
/// `metadata.json` and `transcripts.json`. The MP4 is fragmented (`movieFragmentInterval`), so a crash
/// leaves a playable file and no recovery flow is needed.
public final class RecordingWriter {
    public static let sampleRate = 48_000.0
    public let folder: URL
    public var audioURL: URL { folder.appending(path: "audio.mp4") }

    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let format: CMAudioFormatDescription
    private var writtenFrames: Int64 = 0
    private var paused = false
    private var segments: [[String: Any]] = []
    private let createdAt = Timestamp.now()
    private let meetingName: String
    private let devices: [String: Any]

    public var durationSeconds: Double { Double(writtenFrames) / Self.sampleRate }

    public init(folder: URL, meetingName: String, microphone: String?, systemAudio: String?, fragmentInterval: Double = 10) throws {
        self.folder = folder
        self.meetingName = meetingName
        devices = ["microphone": microphone ?? NSNull(), "system_audio": systemAudio ?? NSNull()]
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        writer = try AVAssetWriter(outputURL: folder.appending(path: "audio.mp4"), fileType: .mp4)
        writer.movieFragmentInterval = CMTime(seconds: fragmentInterval, preferredTimescale: 600)
        input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: Self.sampleRate,
            AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 128_000,
        ])
        input.expectsMediaDataInRealTime = true
        writer.add(input)

        var asbd = AudioStreamBasicDescription(
            mSampleRate: Self.sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 4, mFramesPerPacket: 1,
            mBytesPerFrame: 4, mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        var description: CMAudioFormatDescription?
        try check(CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                                  magicCookie: nil, extensions: nil, formatDescriptionOut: &description))
        format = description!

        guard writer.startWriting() else { throw writer.error ?? AudioError.converter }
        writer.startSession(atSourceTime: .zero)
        try writeMetadata(["status": "recording"])
        try writeTranscripts()
    }

    public func pause() { paused = true }
    public func resume() { paused = false }

    /// Appends 48 kHz mono samples; ignored while paused, so pauses are cut from the file.
    /// Returns false when the samples could not be written (encoder backed up, disk or writer failure).
    @discardableResult public func append(_ samples: [Float]) -> Bool {
        guard !paused, !samples.isEmpty else { return true }
        guard writer.status == .writing, let buffer = try? sampleBuffer(samples) else { return false }
        // Real-time inputs are normally ready; give the encoder a moment rather than dropping audio.
        var waits = 0
        while !input.isReadyForMoreMediaData && waits < 50 { Thread.sleep(forTimeInterval: 0.002); waits += 1 }
        guard input.append(buffer) else { return false }
        writtenFrames += Int64(samples.count)
        return true
    }

    private func sampleBuffer(_ samples: [Float]) throws -> CMSampleBuffer {
        let bytes = samples.count * 4
        var block: CMBlockBuffer?
        try check(CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil,
                                                     customBlockSource: nil, offsetToData: 0, dataLength: bytes, flags: 0, blockBufferOut: &block))
        try samples.withUnsafeBytes { try check(CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: bytes)) }
        var buffer: CMSampleBuffer?
        try check(CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: block!, formatDescription: format, sampleCount: samples.count,
            presentationTimeStamp: CMTime(value: writtenFrames, timescale: CMTimeScale(Self.sampleRate)),
            packetDescriptions: nil, sampleBufferOut: &buffer))
        return buffer!
    }

    /// Adds or replaces a transcript segment (upsert by `sequence`), rewriting `transcripts.json`.
    public func upsertSegment(id: String, text: String, start: Double, end: Double, sequence: Int, confidence: Double = 1) throws {
        let minutes = Int(start) / 60, seconds = Int(start) % 60
        let segment: [String: Any] = [
            "id": id, "text": text, "audio_start_time": start, "audio_end_time": end, "duration": end - start,
            "display_time": String(format: "[%02d:%02d]", minutes, seconds), "confidence": confidence, "sequence_id": sequence,
        ]
        if let index = segments.firstIndex(where: { $0["sequence_id"] as? Int == sequence }) {
            segments[index] = segment
        } else {
            segments.append(segment)
        }
        try writeTranscripts()
    }

    /// Finishes the MP4 and marks the meeting completed.
    public func finish() async throws {
        if writer.status == .writing {
            input.markAsFinished()
            await writer.finishWriting()
        }
        if writer.status == .failed { try? writeMetadata(["status": "error"]); throw writer.error ?? AudioError.converter }
        try writeMetadata(["status": "completed", "completed_at": Timestamp.now(), "duration_seconds": durationSeconds])
        try writeTranscripts()
    }

    // MARK: JSON files (atomic writes; keys other code added are kept)

    private func writeMetadata(_ changes: [String: Any]) throws {
        let url = folder.appending(path: "metadata.json")
        var metadata = (try? JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]) ?? [
            "version": "1.0", "meeting_id": NSNull(), "meeting_name": meetingName, "created_at": createdAt,
            "completed_at": NSNull(), "duration_seconds": NSNull(), "devices": devices, "audio_file": "audio.mp4",
            "transcript_file": "transcripts.json", "sample_rate": Int(Self.sampleRate),
        ]
        metadata.merge(changes) { $1 }
        try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
    }

    private func writeTranscripts() throws {
        let sorted = segments.sorted { ($0["sequence_id"] as? Int ?? 0) < ($1["sequence_id"] as? Int ?? 0) }
        let json: [String: Any] = ["version": "1.0", "segments": sorted, "last_updated": Timestamp.now(), "total_segments": sorted.count]
        try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
            .write(to: folder.appending(path: "transcripts.json"), options: .atomic)
    }
}

private func check(_ status: OSStatus) throws {
    guard status == noErr else { throw AudioError.osStatus("CoreMedia", status) }
}
