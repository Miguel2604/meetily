import Foundation
import Synchronization
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

    func press(_ ptt: inout PushToTalk, _ ms: Int, others: Bool = false) -> PushToTalk.Action? {
        ptt.flagsChanged(keyCode: key, held: true, others: others, at: t0 + .milliseconds(ms))
    }

    func release(_ ptt: inout PushToTalk, _ ms: Int) -> PushToTalk.Action? {
        ptt.flagsChanged(keyCode: key, held: false, others: false, at: t0 + .milliseconds(ms))
    }

    @Test func `a double tap keeps listening until the next press`() {
        var ptt = PushToTalk(keyCode: key)
        #expect(press(&ptt, 0) == .start)
        #expect(release(&ptt, 100) == .cancel)
        #expect(!ptt.isLocked)
        #expect(press(&ptt, 250) == .start)
        #expect(ptt.isLocked)
        #expect(release(&ptt, 350) == nil)
        #expect(ptt.keyDown() == nil) // typing and shortcuts don't end it
        #expect(ptt.flagsChanged(keyCode: 56, held: true, others: true, at: t0 + .seconds(1)) == nil)
        #expect(press(&ptt, 1_500, others: true) == nil)
        #expect(release(&ptt, 1_600) == nil)
        #expect(ptt.isLocked)
        #expect(press(&ptt, 5_000) == .finish)
        #expect(!ptt.isLocked)
        #expect(release(&ptt, 5_100) == nil)
        #expect(press(&ptt, 9_000) == .start) // back to an ordinary hold
        #expect(release(&ptt, 11_000) == .finish)
    }

    @Test func `a slow second tap, typing between taps, or a real hold first don't lock`() {
        var slow = PushToTalk(keyCode: key)
        _ = press(&slow, 0)
        _ = release(&slow, 100)
        #expect(press(&slow, 500) == .start)
        #expect(!slow.isLocked)
        #expect(release(&slow, 2_000) == .finish)

        var typed = PushToTalk(keyCode: key)
        _ = press(&typed, 0)
        _ = release(&typed, 100)
        _ = typed.keyDown()
        #expect(press(&typed, 200) == .start)
        #expect(!typed.isLocked)

        var held = PushToTalk(keyCode: key)
        _ = press(&held, 0)
        #expect(release(&held, 2_000) == .finish)
        #expect(press(&held, 2_100) == .start)
        #expect(!held.isLocked)
    }

    @Test func `other keys alone do nothing`() {
        var ptt = PushToTalk(keyCode: key)
        #expect(ptt.keyDown() == nil)
        #expect(ptt.flagsChanged(keyCode: 58, held: false, others: true, at: t0) == nil)
    }
}

@Suite struct DictationTextTests {
    @Test func `a dictation right after another gets a space when it needs one`() {
        #expect(DictationText.joined(after: "Send it.", "Then call.") == " Then call.")
        #expect(DictationText.joined(after: "Send it", "to Sarah") == " to Sarah")
        #expect(DictationText.joined(after: "Send it\n", "Then call.") == "Then call.")
        #expect(DictationText.joined(after: "Send it ", "Then call.") == "Then call.")
        #expect(DictationText.joined(after: "(", "note") == "note")
        #expect(DictationText.joined(after: "Send it", ", then call") == ", then call")
        #expect(DictationText.joined(after: "Send it", "") == "")
    }

    @Test func `only Chromium 155 and 156 lose a paste`() {
        #expect(DictationText.losesPaste(frameworkVersions: ["156.0.8078.74", "Current"]))
        #expect(DictationText.losesPaste(frameworkVersions: ["155.0.1.2"]))
        #expect(DictationText.losesPaste(frameworkVersions: ["157.0.1.2", "156.0.1.2"])) // a staged update
        #expect(!DictationText.losesPaste(frameworkVersions: ["157.0.1.2"]))
        #expect(!DictationText.losesPaste(frameworkVersions: ["154.0.1.2"]))
        #expect(!DictationText.losesPaste(frameworkVersions: ["A", "Current"])) // Electron
        #expect(!DictationText.losesPaste(frameworkVersions: ["156.0"]))
        #expect(!DictationText.losesPaste(frameworkVersions: ["156.x.1.2"]))
        #expect(!DictationText.losesPaste(frameworkVersions: []))
    }

    @Test func `typing splits long text, keeps surrogate pairs whole and shift-returns line breaks`() {
        #expect(DictationText.strokes("") == [])
        #expect(DictationText.strokes("hi\nyo") == [.text(Array("hi".utf16)), .lineBreak, .text(Array("yo".utf16))])
        #expect(DictationText.strokes("a\r\nb\n\n") == [.text(Array("a".utf16)), .lineBreak, .text(Array("b".utf16)), .lineBreak, .lineBreak])
        let strokes = DictationText.strokes(String(repeating: "x", count: 19) + "😀" + "y")
        #expect(strokes == [.text(Array(String(repeating: "x", count: 19).utf16)), .text(Array("😀y".utf16))])
        let long = DictationText.strokes(String(repeating: "z", count: 45))
        #expect(long.count == 3)
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

    @Test func `a near-silent capture never reaches the model`() async throws {
        final class Counting: TranscriptionEngine {
            let calls = Mutex(0)
            func transcribe(samples: [Float]) async throws -> [Segment] {
                calls.withLock { $0 += 1 }
                return [Segment(text: "Thank you.", start: 0, end: 1)]
            }
        }
        let delivered = Delivered(), engine = Counting()
        let hum = tone(1, rate: 48_000).map { $0 * 0.003 + 0.05 } // about -60 dBFS on a steady offset
        let d = dictation(SampleSource(samples: hum, chunk: 48_000), engine: engine, delivered: delivered)
        try d.start()
        #expect(try await d.finish() == nil)
        #expect(engine.calls.withLock { $0 } == 0)
        #expect(delivered.texts.isEmpty)
        #expect(d.phase == .idle)
    }

    @Test func `only the loudest moment decides whether a capture is silent`() {
        let rate = 48_000.0
        #expect(Dictation.isSilent([], rate: rate))
        #expect(Dictation.isSilent(silence(1, rate: rate), rate: rate))
        #expect(Dictation.isSilent(silence(1, rate: rate).map { $0 + 0.2 }, rate: rate))
        #expect(!Dictation.isSilent(silence(2, rate: rate) + tone(0.1, rate: rate) + silence(2, rate: rate), rate: rate))
        #expect(!Dictation.isSilent(tone(1, rate: rate).map { $0 * 0.05 }, rate: rate)) // a quiet mic still counts
    }

    @Test func `a long pause keeps only its ends, and everything else stays`() {
        let rate = 48_000.0
        func seconds(_ samples: [Float]) -> Double { Double(samples.count) / rate }
        let speech = tone(1, rate: rate)
        let room = (0..<Int(10 * rate)).map { i in 0.002 * Float(sin(Double(i) * 0.37)) } // steady -57 dBFS room noise
        let digital = silence(10, rate: rate)
        for pause in [room, digital] {
            let capped = Dictation.cappingPauses(speech + pause + speech, rate: rate)
            #expect(abs(seconds(capped) - 4.8) < 0.1)
        }
        let trailing = Dictation.cappingPauses(speech + digital, rate: rate)
        #expect(abs(seconds(trailing) - 3.5) < 0.1)
        let short = speech + silence(2, rate: rate) + speech
        #expect(Dictation.cappingPauses(short, rate: rate).count == short.count)
        #expect(Dictation.cappingPauses(speech, rate: rate).count == speech.count)
        #expect(Dictation.cappingPauses(digital, rate: rate).count == digital.count) // nothing heard: untouched
        #expect(Dictation.cappingPauses([], rate: rate).isEmpty)
    }

    @Test func `a second start while listening is ignored`() async throws {
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

    @Test func `the next dictation can start while one is still cleaning, and pastes keep their order`() async throws {
        let delivered = Delivered()
        var mics = [SampleSource(samples: tone(1, rate: 48_000)), SampleSource(samples: tone(2, rate: 48_000))]
        let d = Dictation(capture: { mics.removeFirst() }, engine: { FakeEngine() }, clean: { raw in
            if raw.hasSuffix("1.0") { try? await Task.sleep(for: .milliseconds(200)) }
            return raw
        }, deliver: { delivered.texts.append($0) })
        d.tail = .zero
        try d.start()
        async let first = d.finish()
        while d.phase != .cleaning { await Task.yield() }
        try d.start()
        #expect(d.phase == .listening)
        let second = try await d.finish()
        #expect(try await first == "words 1.0")
        #expect(second == "words 2.0")
        #expect(delivered.texts == ["words 1.0", "words 2.0"])
        #expect(d.phase == .idle)
    }

    @Test func `a tap or chord ends only the capture, so what's processing still pastes`() async throws {
        let delivered = Delivered()
        var mics = [SampleSource(samples: tone(1, rate: 48_000)), SampleSource(samples: tone(2, rate: 48_000))]
        let d = Dictation(capture: { mics.removeFirst() }, engine: { FakeEngine() }, clean: { raw in
            try? await Task.sleep(for: .milliseconds(100))
            return raw
        }, deliver: { delivered.texts.append($0) })
        d.tail = .zero
        try d.start()
        async let first = d.finish()
        while d.phase != .cleaning { await Task.yield() }
        try d.start()
        d.discard()
        #expect(d.phase == .cleaning)
        #expect(try await first == "words 1.0")
        #expect(delivered.texts == ["words 1.0"])
        #expect(try await d.finish() == nil)
    }

    /// A microphone that keeps hearing `level` until it stops.
    final class LiveMic: AudioSource {
        let level: Float
        let stopped = Mutex<ContinuousClock.Instant?>(nil)
        init(level: Float) { self.level = level }
        var droppedSamples: Int { 0 }
        func stop() { stopped.withLock { $0 = .now } }
        func drain() -> [Float] { stopped.withLock { $0 } == nil ? tone(0.04, rate: 48_000).map { $0 * level } : [] }
    }

    @Test func `the tail grows while speech runs, and only to three times its length`() async throws {
        let mic = LiveMic(level: 1)
        let d = Dictation(capture: { mic }, engine: { FakeEngine() }, clean: { $0 }, deliver: { _ in })
        d.tail = .milliseconds(200)
        try d.start()
        let release = ContinuousClock.now
        _ = try await d.finish()
        let held = try #require(mic.stopped.withLock { $0 }) - release
        #expect(held >= .milliseconds(590))
        #expect(held < .milliseconds(900))
    }

    @Test func `the tail stops at its base length once the speaker is quiet`() async throws {
        let mic = LiveMic(level: 0.001)
        let d = Dictation(capture: { mic }, engine: { FakeEngine() }, clean: { $0 }, deliver: { _ in })
        d.tail = .milliseconds(200)
        try d.start()
        let release = ContinuousClock.now
        _ = try await d.finish()
        let held = try #require(mic.stopped.withLock { $0 }) - release
        #expect(held >= .milliseconds(190))
        #expect(held < .milliseconds(450))
    }

    @Test func `a press during the tail starts the next dictation, and both paste in order`() async throws {
        let delivered = Delivered()
        var mics = [SampleSource(samples: tone(1, rate: 48_000)), SampleSource(samples: tone(2, rate: 48_000))]
        var captures = 0
        let d = Dictation(capture: { captures += 1; return mics.removeFirst() }, engine: { FakeEngine() }, clean: { $0 }, deliver: { delivered.texts.append($0) })
        d.tail = .milliseconds(200)
        try d.start()
        async let first = d.finish()
        try await Task.sleep(for: .milliseconds(20)) // inside the first tail
        try d.start()
        #expect(captures == 2) // a start ignored during the tail would leave this at 1
        let second = try await d.finish()
        #expect(try await first == "words 1.0")
        #expect(second == "words 2.0")
        #expect(delivered.texts == ["words 1.0", "words 2.0"])
    }

    @Test func `tails that overlap keep each capture's own audio`() async throws {
        let delivered = Delivered()
        var mics = [1.0, 2.0, 3.0].map { SampleSource(samples: tone($0, rate: 48_000)) }
        let d = Dictation(capture: { mics.removeFirst() }, engine: { FakeEngine() }, clean: { $0 }, deliver: { delivered.texts.append($0) })
        d.tail = .milliseconds(200)
        try d.start()
        async let first = d.finish()
        try await Task.sleep(for: .milliseconds(20))
        try d.start()
        async let second = d.finish()
        try await Task.sleep(for: .milliseconds(20))
        try d.start()
        let third = try await d.finish()
        #expect(try await first == "words 1.0")
        #expect(try await second == "words 2.0")
        #expect(third == "words 3.0")
        #expect(delivered.texts == ["words 1.0", "words 2.0", "words 3.0"])
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

@Suite struct DictationKeyTests {
    // Device-dependent modifier bits: left/right option 0x20/0x40, command 0x08/0x10, control 0x01/0x2000.
    let rightOption: UInt = 0x40 | 0x80000, leftOption: UInt = 0x20 | 0x80000
    let rightCommand: UInt = 0x10 | 0x100000, leftCommand: UInt = 0x08 | 0x100000
    let rightControl: UInt = 0x2000 | 0x40000
    let shift: UInt = 0x02 | 0x20000
    let function: UInt = 0x800000

    @Test func `a saved key reads back, and anything else is Right Option`() {
        #expect(DictationKey(saved: "rightCommand") == .rightCommand)
        #expect(DictationKey(saved: "nonsense") == .rightOption)
        #expect(DictationKey.allCases.count == 4)
    }

    @Test func `each key knows when it's held`() {
        #expect(DictationKey.rightOption.isHeld(flags: rightOption))
        #expect(!DictationKey.rightOption.isHeld(flags: leftOption))
        #expect(DictationKey.rightCommand.isHeld(flags: rightCommand))
        #expect(!DictationKey.rightCommand.isHeld(flags: leftCommand))
        #expect(DictationKey.rightControl.isHeld(flags: rightControl))
        #expect(DictationKey.function.isHeld(flags: function))
        #expect(!DictationKey.function.isHeld(flags: rightOption))
    }

    @Test func `the key's own modifier doesn't count as another one, but its other side does`() {
        #expect(!DictationKey.rightOption.othersDown(flags: rightOption))
        #expect(DictationKey.rightOption.othersDown(flags: rightOption | 0x20))
        #expect(DictationKey.rightOption.othersDown(flags: rightOption | shift))
        #expect(DictationKey.rightOption.othersDown(flags: rightOption | function))
        #expect(!DictationKey.rightCommand.othersDown(flags: rightCommand))
        #expect(DictationKey.rightCommand.othersDown(flags: rightCommand | 0x08))
        #expect(DictationKey.rightCommand.othersDown(flags: rightCommand | rightOption))
        #expect(!DictationKey.rightControl.othersDown(flags: rightControl))
        #expect(DictationKey.rightControl.othersDown(flags: rightControl | 0x01))
        #expect(!DictationKey.function.othersDown(flags: function))
        #expect(DictationKey.function.othersDown(flags: function | rightOption))
        #expect(!DictationKey.function.othersDown(flags: 0))
    }

    @Test func `push to talk follows the chosen key`() {
        var ptt = PushToTalk(key: .rightCommand)
        let t0 = ContinuousClock.now
        #expect(ptt.flagsChanged(keyCode: 61, held: false, others: false, at: t0) == nil)
        #expect(ptt.flagsChanged(keyCode: 54, held: true, others: false, at: t0) == .start)
        #expect(ptt.flagsChanged(keyCode: 54, held: false, others: false, at: t0 + .seconds(1)) == .finish)
    }
}
