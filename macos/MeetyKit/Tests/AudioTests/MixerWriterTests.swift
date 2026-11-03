import AVFoundation
import Foundation
import Testing
@testable import Audio

@Suite struct MixerTests {
    let window = AudioMixer.windowSamples

    @Test func `no window until one stream has a full window`() {
        var mixer = AudioMixer()
        mixer.add(mic: [Float](repeating: 0.1, count: window - 1))
        let none = mixer.nextWindow()
        #expect(none == nil)
        mixer.add(mic: [0.1])
        let first = mixer.nextWindow()
        #expect(first?.count == window)
        let second = mixer.nextWindow()
        #expect(second == nil)
    }

    @Test func `sums mic and system and pads the short one with silence`() throws {
        var mixer = AudioMixer()
        mixer.add(mic: [Float](repeating: 0.25, count: window))
        mixer.add(system: [Float](repeating: 0.5, count: 10))
        let out = mixer.nextWindow()
        let mixed = try #require(out)
        #expect(mixed[0] == 0.75)
        #expect(mixed[9] == 0.75)
        #expect(mixed[10] == 0.25)
    }

    @Test func `over-range sums scale back to full scale`() throws {
        var mixer = AudioMixer()
        mixer.add(mic: [Float](repeating: 0.8, count: window))
        mixer.add(system: [Float](repeating: 0.7, count: window))
        let out = mixer.nextWindow()
        let mixed = try #require(out)
        #expect(mixed.allSatisfy { $0 == 1 })
        var negative = AudioMixer()
        negative.add(mic: [Float](repeating: -0.9, count: window))
        negative.add(system: [Float](repeating: -0.9, count: window))
        let clipped = negative.nextWindow()
        #expect(try #require(clipped).allSatisfy { $0 == -1 })
    }

    @Test func `overflow keeps the newest samples`() {
        var mixer = AudioMixer()
        mixer.add(mic: [Float](repeating: 0, count: AudioMixer.maxBufferSamples) + [1])
        #expect(mixer.bufferedMic == AudioMixer.maxBufferSamples)
        #expect(mixer.droppedMic == 1)
    }

    @Test func `flush returns the partial tail`() {
        var mixer = AudioMixer()
        mixer.add(mic: [0.1, 0.1, 0.1])
        let tail = mixer.flush()
        #expect(tail.count == 3)
        let empty = mixer.flush()
        #expect(empty.isEmpty)
    }
}

let crashFile = FileManager.default.temporaryDirectory.appending(path: "meety-crash-test/audio.mp4")

func fixtureSamples() throws -> [Float] {
    let file = try AVAudioFile(forReading: fixtures.appending(path: "he_aac_48k_5s.m4a"))
    let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
    try file.read(into: buffer)
    return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
}

func duration(of url: URL) async throws -> Double {
    try await AVURLAsset(url: url).load(.duration).seconds
}

@Suite(.serialized) struct RecordingWriterTests {
    func tempFolder() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "meety-writer-\(UUID().uuidString)")
    }

    @Test func `writes audio, metadata and transcripts in the meeting folder layout`() async throws {
        let folder = tempFolder()
        let writer = try RecordingWriter(folder: folder, meetingName: "Daily", microphone: "Mic", systemAudio: "Speakers")
        let samples = try fixtureSamples()
        writer.append(samples)
        writer.pause()
        writer.append(samples) // dropped while paused
        writer.resume()
        writer.append(samples)
        try writer.upsertSegment(id: "transcript-1", text: "hello", start: 0.5, end: 1.5, sequence: 0)
        try writer.upsertSegment(id: "transcript-1", text: "hello there", start: 0.5, end: 1.7, sequence: 0)
        try writer.upsertSegment(id: "transcript-2", text: "bye", start: 63.2, end: 64, sequence: 1)
        try await writer.finish()

        let expected = Double(samples.count * 2) / 48_000
        let written = try await duration(of: folder.appending(path: "audio.mp4"))
        #expect(abs(written - expected) < 0.1, "file \(written) s, expected \(expected) s")
        let metadata = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appending(path: "metadata.json"))) as! [String: Any]
        #expect(metadata["status"] as? String == "completed")
        #expect(metadata["audio_file"] as? String == "audio.mp4")
        #expect(metadata["meeting_name"] as? String == "Daily")
        #expect(metadata["sample_rate"] as? Int == 48_000)
        #expect(abs((metadata["duration_seconds"] as? Double ?? 0) - expected) < 0.001)
        #expect((metadata["devices"] as? [String: String])?["microphone"] == "Mic")
        let transcripts = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appending(path: "transcripts.json"))) as! [String: Any]
        let segments = transcripts["segments"] as! [[String: Any]]
        #expect(segments.count == 2)
        #expect(segments[0]["text"] as? String == "hello there")
        #expect(segments[1]["display_time"] as? String == "[01:03]")
        #expect(transcripts["total_segments"] as? Int == 2)
    }

    @Test func `metadata keeps keys other code added`() async throws {
        let folder = tempFolder()
        let writer = try RecordingWriter(folder: folder, meetingName: "m", microphone: nil, systemAudio: nil)
        var metadata = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appending(path: "metadata.json"))) as! [String: Any]
        metadata["detected_summary_language"] = "en"
        try JSONSerialization.data(withJSONObject: metadata).write(to: folder.appending(path: "metadata.json"))
        writer.append([Float](repeating: 0, count: 4800))
        try await writer.finish()
        let final = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appending(path: "metadata.json"))) as! [String: Any]
        #expect(final["detected_summary_language"] as? String == "en")
        #expect(final["status"] as? String == "completed")
    }

    @Test func `audio survives the process dying mid-recording`() async throws {
        try? FileManager.default.removeItem(at: crashFile.deletingLastPathComponent())
        await #expect(processExitsWith: .exitCode(9)) {
            let writer = try RecordingWriter(folder: crashFile.deletingLastPathComponent(), meetingName: "crash",
                                             microphone: nil, systemAudio: nil, fragmentInterval: 1)
            let samples = try fixtureSamples()
            writer.append(samples)
            writer.append(samples)
            try await Task.sleep(for: .seconds(3)) // let fragments reach disk
            _exit(9)
        }
        let recovered = try await duration(of: crashFile)
        #expect(recovered > 5)
    }
}
