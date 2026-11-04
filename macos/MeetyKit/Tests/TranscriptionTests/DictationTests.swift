import Foundation
import Testing
@testable import Transcription

@Suite struct PushToTalkTests {
    let t0 = ContinuousClock.now
    let key: UInt16 = 61

    @Test func `holding the key alone starts, releasing finishes`() {
        var ptt = PushToTalk(keyCode: key)
        #expect(ptt.flagsChanged(keyCode: key, held: true, others: false, at: t0) == .start)
        #expect(ptt.flagsChanged(keyCode: key, held: false, others: false, at: t0 + .seconds(2)) == .finish)
    }

    @Test func `a quick tap cancels`() {
        var ptt = PushToTalk(keyCode: key)
        #expect(ptt.flagsChanged(keyCode: key, held: true, others: false, at: t0) == .start)
        #expect(ptt.flagsChanged(keyCode: key, held: false, others: false, at: t0 + .milliseconds(100)) == .cancel)
    }

    @Test func `typing while holding is a shortcut, so it cancels and the release is ignored`() {
        var ptt = PushToTalk(keyCode: key)
        _ = ptt.flagsChanged(keyCode: key, held: true, others: false, at: t0)
        #expect(ptt.keyDown() == .cancel)
        #expect(ptt.keyDown() == nil)
        #expect(ptt.flagsChanged(keyCode: key, held: false, others: false, at: t0 + .seconds(2)) == nil)
    }

    @Test func `another modifier, before or during the hold, means no dictation`() {
        var ptt = PushToTalk(keyCode: key)
        #expect(ptt.flagsChanged(keyCode: key, held: true, others: true, at: t0) == nil)
        #expect(ptt.flagsChanged(keyCode: key, held: false, others: true, at: t0 + .seconds(1)) == nil)
        #expect(ptt.flagsChanged(keyCode: key, held: true, others: false, at: t0 + .seconds(2)) == .start)
        #expect(ptt.flagsChanged(keyCode: 56, held: true, others: true, at: t0 + .seconds(3)) == .cancel)
        #expect(ptt.flagsChanged(keyCode: key, held: false, others: true, at: t0 + .seconds(4)) == nil)
    }

    @Test func `other keys alone do nothing`() {
        var ptt = PushToTalk(keyCode: key)
        #expect(ptt.keyDown() == nil)
        #expect(ptt.flagsChanged(keyCode: 58, held: false, others: true, at: t0) == nil)
    }
}

@MainActor @Suite struct DictationTests {
    final class Delivered { var texts: [String] = [] }

    func dictation(_ mic: SampleSource, engine: any TranscriptionEngine = FakeEngine(), delivered: Delivered,
                   clean: @escaping (String) async -> String = { $0.uppercased() }) -> Dictation {
        let d = Dictation(capture: { mic }, engine: { engine }, clean: clean, deliver: { delivered.texts.append($0) })
        d.tail = .zero
        return d
    }

    @Test func `transcribes what was captured at 16 kHz, cleans it and delivers it`() async throws {
        let delivered = Delivered()
        let d = dictation(SampleSource(samples: tone(2, rate: 48_000), chunk: 4_800), delivered: delivered)
        try d.start()
        #expect(d.phase == .listening)
        let text = try await d.finish()
        #expect(text == "WORDS 2.0")
        #expect(delivered.texts == ["WORDS 2.0"])
        #expect(d.phase == .idle)
    }

    @Test func `cancel stops listening and delivers nothing`() async throws {
        let delivered = Delivered()
        let d = dictation(SampleSource(samples: tone(2, rate: 48_000)), delivered: delivered)
        try d.start()
        d.cancel()
        #expect(d.phase == .idle)
        #expect(try await d.finish() == nil)
        #expect(delivered.texts.isEmpty)
    }

    @Test func `cancelling while it transcribes or cleans delivers nothing, and a new dictation can start`() async throws {
        final class Box { var dictation: Dictation? }
        let delivered = Delivered(), box = Box()
        let mic = SampleSource(samples: tone(1, rate: 48_000))
        let d = Dictation(capture: { mic }, engine: { FakeEngine() }, clean: { raw in
            box.dictation?.cancel()
            return raw
        }, deliver: { delivered.texts.append($0) })
        box.dictation = d
        d.tail = .zero
        try d.start()
        #expect(try await d.finish() == nil)
        #expect(delivered.texts.isEmpty)
        #expect(d.phase == .idle)
        try d.start()
        #expect(d.phase == .listening)
    }

    @Test func `silence delivers nothing`() async throws {
        final class Mute: TranscriptionEngine { func transcribe(samples: [Float]) async throws -> [Segment] { [] } }
        let delivered = Delivered()
        let d = dictation(SampleSource(samples: silence(1, rate: 48_000)), engine: Mute(), delivered: delivered)
        try d.start()
        #expect(try await d.finish() == nil)
        #expect(delivered.texts.isEmpty)
    }

    @Test func `a second start while busy is ignored`() async throws {
        let delivered = Delivered()
        var captures = 0
        let mic = SampleSource(samples: tone(1, rate: 48_000))
        let d = Dictation(capture: { captures += 1; return mic }, engine: { FakeEngine() }, clean: { $0 }, deliver: { delivered.texts.append($0) })
        d.tail = .zero
        try d.start()
        try d.start()
        #expect(captures == 1)
        _ = try await d.finish()
        #expect(delivered.texts == ["words 1.0"])
    }

    @Test func `engine errors reach the caller and leave it idle`() async throws {
        struct NotReady: Error {}
        let d = Dictation(capture: { SampleSource(samples: tone(1, rate: 48_000)) }, engine: { throw NotReady() },
                          clean: { $0 }, deliver: { _ in Issue.record("delivered") })
        d.tail = .zero
        try d.start()
        await #expect(throws: NotReady.self) { try await d.finish() }
        #expect(d.phase == .idle)
    }
}
