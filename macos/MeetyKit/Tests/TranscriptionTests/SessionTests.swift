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
