import AVFoundation
import Core
import Foundation
import Testing
@testable import Transcription

let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../Fixtures").standardized

func writeWAV(_ samples: [Float], rate: Double = 48_000, to url: URL) throws {
    let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
    buffer.frameLength = AVAudioFrameCount(samples.count)
    samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
    try file.write(from: buffer)
}

/// Two bursts at 48 kHz, 3 s apart so the batch VAD (2 s redemption) keeps them separate.
func meetingWAV() throws -> URL {
    let url = tempDir().appending(path: "Client call.wav")
    try writeWAV(silence(1, rate: 48_000) + tone(2, rate: 48_000) + silence(3, rate: 48_000) + tone(1.5, rate: 48_000) + silence(1, rate: 48_000), to: url)
    return url
}

func json(_ url: URL) throws -> [String: Any] {
    try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
}

@Suite struct DecodeTests {
    @Test func `decodes AAC to 16 kHz mono with progress`() async throws {
        let seen = Progress()
        let samples = try await decodeAudio(fixtures.appending(path: "he_aac_48k_5s.m4a")) { seen.add($0) }
        #expect(abs(Double(samples.count) / 16_000 - 5) < 0.2) // AAC priming and padding
        #expect(seen.values.last == 1)
    }

    @Test func `unsupported and unreadable files are refused`() async throws {
        let ogg = tempDir().appending(path: "talk.ogg")
        FileManager.default.createFile(atPath: ogg.path, contents: Data("OggS".utf8))
        #expect(throws: ImportError.unsupported("ogg")) { try OfflineTranscription.validate(ogg) }
        let broken = tempDir().appending(path: "broken.m4a")
        FileManager.default.createFile(atPath: broken.path, contents: Data("nope".utf8))
        await #expect(throws: (any Error).self) { try await decodeAudio(broken) }
    }
}

@Suite struct ImportTests {
    let recordings = tempDir()

    @Test func `imports a file into a new meeting folder and the database`() async throws {
        let store = try tempStore()
        let seen = Progress()
        let result = try await OfflineTranscription.importAudio(
            try meetingWAV(), title: "Client call", recordingsFolder: recordings, store: store,
            engine: FakeEngine(), detector: EnergyDetector()) { seen.add($0.fraction) }

        #expect(result.segmentCount == 2)
        #expect(abs(result.duration - 8.5) < 0.05)
        #expect(seen.values.last == 1)
        #expect(zip(seen.values, seen.values.dropFirst()).allSatisfy { $0 <= $1 }, "\(seen.values)")
        let transcripts = try await store.transcripts(meetingID: result.meetingID)
        #expect(transcripts.map(\.transcript) == ["words 2.7", "words 2.2"])
        let folder = URL(fileURLWithPath: try #require(try await store.meeting(id: result.meetingID)?.folderPath))
        #expect(folder.lastPathComponent.hasPrefix("Client call_"))
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: "audio.wav").path))
        #expect(try json(folder.appending(path: "transcripts.json"))["total_segments"] as? Int == 2)
        let metadata = try json(folder.appending(path: "metadata.json"))
        #expect(metadata["source"] as? String == "import")
        #expect(metadata["meeting_id"] as? String == result.meetingID)
        #expect(metadata["audio_file"] as? String == "audio.wav")
    }

    @Test func `cancelling an import leaves no folder and no meeting`() async throws {
        let store = try tempStore()
        let source = try meetingWAV()
        let task = Task {
            try await OfflineTranscription.importAudio(source, title: "Cancelled", recordingsFolder: recordings, store: store,
                                                       engine: FakeEngine(delay: .seconds(5)), detector: EnergyDetector())
        }
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try await store.meetings().isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: recordings.path).isEmpty)
    }

    @Test func `retranscribing replaces the transcript and updates the folder files`() async throws {
        let store = try tempStore()
        let imported = try await OfflineTranscription.importAudio(
            try meetingWAV(), title: "Retry", recordingsFolder: recordings, store: store, engine: FakeEngine(), detector: EnergyDetector())
        let count = try await OfflineTranscription.retranscribe(
            meetingID: imported.meetingID, store: store, engine: FakeEngine(prefix: "again"), detector: EnergyDetector())
        #expect(count == 2)
        #expect(try await store.transcripts(meetingID: imported.meetingID).map(\.transcript) == ["again 2.7", "again 2.2"])
        let folder = URL(fileURLWithPath: try #require(try await store.meeting(id: imported.meetingID)?.folderPath))
        let segments = try json(folder.appending(path: "transcripts.json"))["segments"] as? [[String: Any]]
        #expect(segments?.compactMap { $0["text"] as? String } == ["again 2.7", "again 2.2"])
        let metadata = try json(folder.appending(path: "metadata.json"))
        #expect(metadata["retranscribed_at"] as? String != nil)
        #expect(metadata["meeting_name"] as? String == "Retry") // existing keys kept
    }

    @Test func `a cancelled retranscription keeps the old transcript`() async throws {
        let store = try tempStore()
        let imported = try await OfflineTranscription.importAudio(
            try meetingWAV(), title: "Keep", recordingsFolder: recordings, store: store, engine: FakeEngine(), detector: EnergyDetector())
        let task = Task {
            try await OfflineTranscription.retranscribe(meetingID: imported.meetingID, store: store,
                                                        engine: FakeEngine(prefix: "lost", delay: .seconds(5)), detector: EnergyDetector())
        }
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try await store.transcripts(meetingID: imported.meetingID).map(\.transcript) == ["words 2.7", "words 2.2"])
    }

    @Test func `retranscribing a meeting without audio fails clearly`() async throws {
        let store = try tempStore()
        let id = try await store.saveMeeting(title: "No audio", segments: [], folderPath: tempDir().path)
        await #expect(throws: ImportError.noAudio) {
            try await OfflineTranscription.retranscribe(meetingID: id, store: store, engine: FakeEngine(), detector: EnergyDetector())
        }
    }
}
