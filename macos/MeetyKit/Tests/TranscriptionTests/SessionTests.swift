import Audio
import Core
import Foundation
import Testing
@testable import Transcription

/// Loud frames are speech. Stands in for Silero, which needs a model.
struct EnergyDetector: VoiceDetector {
    var frameSize: Int { 480 } // 30 ms
    func speechProbability(_ frame: [Float]) async throws -> Float { AudioLevel(samples: frame).rms > 0.01 ? 1 : 0 }
}

func tone(_ seconds: Double, rate: Double = 16_000) -> [Float] {
    (0..<Int(seconds * rate)).map { 0.3 * Float(sin(2 * .pi * 220 * Double($0) / rate)) }
}

func silence(_ seconds: Double, rate: Double = 16_000) -> [Float] { [Float](repeating: 0, count: Int(seconds * rate)) }

@Suite struct SpeechSegmenterTests {
    let speech = silence(1) + tone(2) + silence(2) + tone(1.5) + silence(1)

    @Test func `cuts speech bursts with padding at the original times`() async throws {
        var segmenter = SpeechSegmenter(detector: EnergyDetector(), config: .live)
        var chunks = try await segmenter.process(speech)
        chunks += try await segmenter.flush()
        try #require(chunks.count == 2)
        #expect(abs(chunks[0].start - 0.7) < 0.04)  // 300 ms pre-pad
        #expect(abs(chunks[0].end - 3.4) < 0.04)    // 400 ms post-pad
        #expect(abs(chunks[1].start - 4.7) < 0.04)
        #expect(abs(chunks[1].end - 6.9) < 0.04)
        for chunk in chunks { #expect(chunk.samples.count == Int(((chunk.end - chunk.start) * 16_000).rounded())) }
    }

    @Test func `feeding odd-sized pieces gives the same chunks`() async throws {
        var whole = SpeechSegmenter(detector: EnergyDetector(), config: .live)
        let expected = try await whole.process(speech) + whole.flush()
        var pieces = SpeechSegmenter(detector: EnergyDetector(), config: .live)
        var got: [SpeechChunk] = []
        var index = 0
        while index < speech.count {
            let end = min(index + 777, speech.count)
            got += try await pieces.process(Array(speech[index..<end]))
            index = end
        }
        got += try await pieces.flush()
        #expect(got == expected)
    }

    @Test func `flush closes speech still open at the end`() async throws {
        var segmenter = SpeechSegmenter(detector: EnergyDetector(), config: .live)
        #expect(try await segmenter.process(silence(0.5) + tone(1)).isEmpty)
        let chunks = try await segmenter.flush()
        try #require(chunks.count == 1)
        #expect(abs(chunks[0].end - 1.5) < 0.001)
    }

    @Test func `flush ends a burst that is already in silence at the post-pad`() async throws {
        var segmenter = SpeechSegmenter(detector: EnergyDetector(), config: .batch)
        let chunks = try await segmenter.process(tone(1) + silence(1)) + segmenter.flush()
        try #require(chunks.count == 1)
        #expect(abs(chunks[0].end - 1.4) < 0.04)
    }

    @Test func `continuous speech is cut at the maximum length`() async throws {
        var segmenter = SpeechSegmenter(detector: EnergyDetector(), config: .live)
        let chunks = try await segmenter.process(tone(70)) + segmenter.flush()
        #expect(chunks.count == 3)
        #expect(chunks.allSatisfy { $0.end - $0.start <= SpeechSegmenter.Config.live.maxSpeech + 0.001 })
        #expect(zip(chunks, chunks.dropFirst()).allSatisfy { $0.end == $1.start })
    }

    @Test func `blips shorter than the minimum are dropped, and a long pause keeps one segment open in batch mode`() async throws {
        var live = SpeechSegmenter(detector: EnergyDetector(), config: .live)
        #expect(try await live.process(silence(1) + tone(0.1) + silence(1)).isEmpty)
        var batch = SpeechSegmenter(detector: EnergyDetector(), config: .batch)
        let chunks = try await batch.process(tone(1) + silence(1) + tone(1) + silence(3)) + batch.flush()
        #expect(chunks.count == 1)
    }
}

struct FailingDetector: VoiceDetector {
    struct Failure: Error {}
    var frameSize: Int { 480 }
    func speechProbability(_ frame: [Float]) async throws -> Float { throw Failure() }
}

/// Answers "words:<seconds>" per chunk, optionally slowly.
final class FakeEngine: TranscriptionEngine {
    let prefix: String
    let delay: Duration
    init(prefix: String = "words", delay: Duration = .zero) {
        self.prefix = prefix
        self.delay = delay
    }
    func transcribe(samples: [Float]) async throws -> [Segment] {
        try await Task.sleep(for: delay)
        let seconds = Double(samples.count) / 16_000
        return [Segment(text: String(format: "%@ %.1f", prefix, seconds), start: 0, end: seconds)]
    }
}

func tempStore() throws -> Store { try Store(path: tempDir().appending(path: "meeting_minutes.sqlite").path) }

@Suite struct RecordingSessionTests {
    /// 48 kHz: two bursts the energy VAD will find.
    let meeting = silence(1, rate: 48_000) + tone(2, rate: 48_000) + silence(2, rate: 48_000) + tone(1.5, rate: 48_000) + silence(1, rate: 48_000)

    func run(_ session: RecordingSession, until source: SampleSource) async throws -> String {
        await session.start()
        while !source.isFinished { try await Task.sleep(for: .milliseconds(10)) }
        return try await session.stop()
    }

    @Test func `records, transcribes in order, and saves the meeting`() async throws {
        let store = try tempStore()
        let folder = tempDir().appending(path: "Standup_2026-11-04_09-00")
        let mic = SampleSource(samples: meeting, chunk: 24_000)
        let session = try RecordingSession(title: "Standup", folder: folder, store: store, engine: FakeEngine(),
                                           detector: EnergyDetector(), microphone: mic, system: nil)
        let collected = Task { await session.events.reduce(into: [RecordingSession.Event]()) { $0.append($1) } }
        let id = try await run(session, until: mic)

        let transcripts = try await store.transcripts(meetingID: id)
        #expect(transcripts.map(\.transcript) == ["words 2.7", "words 2.2"])
        #expect(transcripts.allSatisfy { $0.speaker == nil && Timestamp.parse($0.timestamp) != nil })
        #expect(abs((transcripts.first?.audioStartTime ?? 0) - 0.7) < 0.05)
        #expect(try await store.meeting(id: id)?.folderPath == folder.path)
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: "audio.mp4").path))
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appending(path: "transcripts.json"))) as! [String: Any]
        #expect(json["total_segments"] as? Int == 2)

        let events = await collected.value // the stream finishes on stop
        let texts = events.compactMap { if case .segment(let s) = $0 { s.text } else { nil } }
        #expect(texts == ["words 2.7", "words 2.2"])
        #expect(events.last == .saved(id))
    }

    @Test func `pausing keeps audio captured before the pause`() async throws {
        let store = try tempStore()
        let folder = tempDir().appending(path: "PauseStop")
        let mic = SampleSource(samples: tone(0.3, rate: 48_000), chunk: 4_800) // less than one mixer window
        let session = try RecordingSession(title: "PauseStop", folder: folder, store: store, engine: FakeEngine(),
                                           detector: EnergyDetector(), microphone: mic, system: nil)
        await session.start()
        while !mic.isFinished { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(60)) // one more poll drains the source
        await session.pause()
        _ = try await session.stop()
        let metadata = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appending(path: "metadata.json"))) as! [String: Any]
        #expect(abs((metadata["duration_seconds"] as? Double ?? 0) - 0.3) < 0.01)
    }

    @Test func `a voice detection failure on stop still saves the recording`() async throws {
        let store = try tempStore()
        let folder = tempDir().appending(path: "VADFails")
        let mic = SampleSource(samples: meeting, chunk: 24_000)
        let session = try RecordingSession(title: "VADFails", folder: folder, store: store, engine: FakeEngine(),
                                           detector: FailingDetector(), microphone: mic, system: nil)
        let id = try await run(session, until: mic)
        #expect(try await store.meeting(id: id) != nil)
        let metadata = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appending(path: "metadata.json"))) as! [String: Any]
        #expect(metadata["status"] as? String == "completed")
    }

    @Test func `audio captured while paused is left out`() async throws {
        let store = try tempStore()
        let folder = tempDir().appending(path: "Paused")
        let mic = SampleSource(samples: meeting, chunk: 24_000)
        let session = try RecordingSession(title: "Paused", folder: folder, store: store, engine: FakeEngine(),
                                           detector: EnergyDetector(), microphone: mic, system: nil)
        await session.pause()
        let id = try await run(session, until: mic)
        #expect(try await store.transcripts(meetingID: id).isEmpty)
    }

    @Test func `a slow engine raises a falling-behind warning and still finishes every chunk`() async throws {
        let store = try tempStore()
        let mic = SampleSource(samples: meeting + meeting, chunk: 96_000)
        let session = try RecordingSession(title: "Slow", folder: tempDir().appending(path: "Slow"), store: store,
                                           engine: FakeEngine(delay: .milliseconds(150)), detector: EnergyDetector(),
                                           microphone: mic, system: nil, backlogWarning: 2)
        let collected = Task { await session.events.reduce(into: [RecordingSession.Event]()) { $0.append($1) } }
        let id = try await run(session, until: mic)
        #expect(try await store.transcripts(meetingID: id).count == 4)
        let warnings = await collected.value.filter { if case .warning = $0 { true } else { false } }
        #expect(!warnings.isEmpty)
    }
}

/// Silero + Parakeet on synthesized speech (MEETY_REAL_MODELS=1; downloads the small VAD model once).
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["MEETY_REAL_MODELS"] == "1"))
struct RealVADTests {
    @Test func `silero finds the speech and parakeet reads it`() async throws {
        let vad = try await VoiceModel.load(directory: Paths.models.appending(path: "vad"))
        var segmenter = SpeechSegmenter(detector: vad.detector(), config: .batch)
        let audio = silence(1) + (try spokenSamples("The quarterly budget review is on Friday.")) + silence(1)
        let chunks = try await segmenter.process(audio) + segmenter.flush()
        try #require(!chunks.isEmpty)
        let engine = try await ParakeetModels(directory: Paths.parakeetModels).engine(.phonon2)
        var text = ""
        for chunk in chunks { text += try await engine.transcribe(samples: chunk.samples).map(\.text).joined() }
        print("VAD chunks \(chunks.map { ($0.start, $0.end) }): \(text)")
        #expect(text.lowercased().contains("budget"))
    }
}

/// S22 measurement: a 60 s real-time session with Silero + Parakeet Ultra, printing CPU and memory.
/// MEETY_PERF=1 swift test -c release --filter SessionPerformance
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["MEETY_PERF"] == "1"))
struct SessionPerformanceTests {
    @Test func `live session cpu and memory`() async throws {
        let vad = try await VoiceModel.load(directory: Paths.models.appending(path: "vad"))
        let engine = try await ParakeetModels(directory: Paths.parakeetModels).engine(.ultra)
        let line = try spokenSamples("We reviewed the quarterly budget and agreed to move the launch to Friday after the design review.", rate: 48_000)
        var audio: [Float] = []
        while audio.count < 60 * 48_000 { audio += line + silence(2, rate: 48_000) }
        let store = try tempStore()
        let mic = SampleSource(samples: audio, chunk: 960) // 20 ms per 20 ms poll: real time
        let session = try RecordingSession(title: "Perf", folder: tempDir().appending(path: "Perf"), store: store,
                                           engine: engine, detector: vad.detector(), microphone: mic, system: nil)
        let (cpu0, wall0) = (cpuSeconds(), Date())
        await session.start()
        while !mic.isFinished { try await Task.sleep(for: .milliseconds(50)) }
        let id = try await session.stop()
        let wall = Date().timeIntervalSince(wall0)
        let cpu = cpuSeconds() - cpu0
        print(String(format: "session %.1f s wall, %.1f s CPU = %.1f%% of one core, footprint %.0f MB, %d segments",
                     wall, cpu, 100 * cpu / wall, footprintMB(), try await store.transcripts(meetingID: id).count))
        #expect(try await !store.transcripts(meetingID: id).isEmpty)
    }

    func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
    }

    func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        _ = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) } }
        return Double(info.phys_footprint) / 1_048_576
    }
}

/// The app's capture path end to end: live microphone + system tap → session → file (MEETY_REAL_DEVICES=1).
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["MEETY_REAL_DEVICES"] == "1"))
struct RealCaptureSessionTests {
    @Test func `a recording is as long as the time it ran`() async throws {
        let folder = tempDir().appending(path: "RealCapture")
        let microphone = try LiveMicrophone(preferred: nil) // the app's order: microphone (voice processing) first
        let system = SystemAudioCapture()
        try system.start()
        let session = try RecordingSession(title: "RealCapture", folder: folder, store: try tempStore(), engine: FakeEngine(),
                                           detector: EnergyDetector(), microphone: microphone, system: system)
        let start = Date()
        await session.start()
        try await Task.sleep(for: .seconds(6))
        _ = try await session.stop()
        let wall = Date().timeIntervalSince(start)
        let metadata = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appending(path: "metadata.json"))) as! [String: Any]
        let recorded = try #require(metadata["duration_seconds"] as? Double)
        #expect(abs(recorded - wall) < 1.0, "recorded \(recorded) s in \(wall) s")
    }
}

/// The whole live path with real models: speech played through the speakers reaches the microphone and the
/// system tap and comes back as text (MEETY_REAL_DEVICES=1 MEETY_REAL_MODELS=1; unmute the output first).
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["MEETY_REAL_DEVICES"] == "1"
                              && ProcessInfo.processInfo.environment["MEETY_REAL_MODELS"] == "1"))
struct RealLiveTranscriptionTests {
    @Test func `spoken sentences come back as text in a recording of the right length`() async throws {
        let engine = try await ParakeetModels(directory: Paths.parakeetModels).engine(.ultra)
        let vad = try await VoiceModel.load(directory: Paths.models.appending(path: "vad"))
        let folder = tempDir().appending(path: "RealLive")
        let store = try tempStore()
        let microphone = try LiveMicrophone(preferred: nil)
        let system = SystemAudioCapture()
        try system.start()
        let session = try RecordingSession(title: "RealLive", folder: folder, store: store, engine: engine,
                                           detector: vad.detector(), microphone: microphone, system: system)
        let start = Date()
        await session.start()
        for sentence in ["We reviewed the quarterly budget and agreed to ship the beta on Friday.",
                         "Maria owns the launch checklist.", "Next week we will test the onboarding flow."] {
            let say = Process()
            say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            say.arguments = ["-v", "Samantha", sentence]
            try say.run()
            say.waitUntilExit()
            try await Task.sleep(for: .seconds(2))
        }
        let id = try await session.stop()
        let wall = Date().timeIntervalSince(start)
        let text = try await store.transcripts(meetingID: id).map(\.transcript).joined(separator: " | ")
        let metadata = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appending(path: "metadata.json"))) as! [String: Any]
        let recorded = try #require(metadata["duration_seconds"] as? Double)
        print("recorded \(recorded) s in \(wall) s: \(text)")
        #expect(abs(recorded - wall) < 1.5)
        #expect(["friday", "checklist", "onboarding"].allSatisfy(text.lowercased().contains)) // through speakers and mic, one word can slip
    }
}

