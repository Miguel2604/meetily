import Audio
import Foundation
import Observation
import os

private let log = Logger(subsystem: "com.meetily.ai", category: "dictation")

/// The modifier key that dictates. Only modifiers a hold can't type with, and no Right Shift: the microphone opens on
/// the press, so it would open for every capital letter.
public enum DictationKey: String, CaseIterable, Sendable {
    case rightOption, rightCommand, rightControl, function

    public init(saved: String) { self = Self(rawValue: saved) ?? .rightOption }

    public var keyCode: UInt16 {
        switch self {
        case .rightOption: 61
        case .rightCommand: 54
        case .rightControl: 62
        case .function: 63
        }
    }

    public var title: String {
        switch self {
        case .rightOption: "Right Option (⌥)"
        case .rightCommand: "Right Command (⌘)"
        case .rightControl: "Right Control (⌃)"
        case .function: "Fn (🌐)"
        }
    }

    public var symbol: String {
        switch self {
        case .rightOption: "⌥"
        case .rightCommand: "⌘"
        case .rightControl: "⌃"
        case .function: "fn"
        }
    }

    // NSEvent modifier flags: the device-independent bit for each modifier, and the device bit for each side.
    private static let option: UInt = 0x80000, command: UInt = 0x100000, control: UInt = 0x40000
    private static let shift: UInt = 0x20000, fn: UInt = 0x800000

    private var bits: (held: UInt, group: UInt, otherSide: UInt) {
        switch self {
        case .rightOption: (0x40, Self.option, 0x20)
        case .rightCommand: (0x10, Self.command, 0x08)
        case .rightControl: (0x2000, Self.control, 0x01)
        case .function: (Self.fn, Self.fn, 0)
        }
    }

    public func isHeld(flags: UInt) -> Bool { flags & bits.held != 0 }

    /// Any other modifier is down, this one's other side included.
    public func othersDown(flags: UInt) -> Bool {
        let groups = Self.option | Self.command | Self.control | Self.shift | Self.fn
        return flags & (groups & ~bits.group | bits.otherSide) != 0
    }
}

/// Hold-to-talk on one modifier key held alone (Right Option by default), fed from the app's key monitors.
/// Typing or another modifier during the hold is a keyboard shortcut, so it cancels. A double tap keeps listening
/// hands-free until the next press, through typing and shortcuts.
public struct PushToTalk: Sendable {
    public enum Action: Sendable, Equatable { case start, finish, cancel }

    /// Virtual key code of the trigger; 61 is Right Option.
    public let keyCode: UInt16
    /// Shorter holds are taps, not dictation.
    public let minimumHold: Duration
    /// A press this soon after a tap locks the dictation.
    public let doubleTap: Duration = .milliseconds(300)
    public private(set) var isLocked = false
    private var pressedAt: ContinuousClock.Instant?
    private var tappedAt: ContinuousClock.Instant?

    public init(key: DictationKey) { self.init(keyCode: key.keyCode) }

    public init(keyCode: UInt16 = 61, minimumHold: Duration = .milliseconds(300)) {
        self.keyCode = keyCode
        self.minimumHold = minimumHold
    }

    /// A modifier changed. `held`: the trigger is down; `others`: any other modifier is down.
    public mutating func flagsChanged(keyCode: UInt16, held: Bool, others: Bool, at now: ContinuousClock.Instant) -> Action? {
        let pressed = keyCode == self.keyCode && held && !others
        if isLocked {
            guard pressed else { return nil }
            isLocked = false
            return .finish
        }
        guard let pressedAt else {
            guard pressed else { return nil }
            isLocked = tappedAt.map { now - $0 < doubleTap } ?? false
            tappedAt = nil
            self.pressedAt = isLocked ? nil : now
            return .start
        }
        self.pressedAt = nil
        guard keyCode == self.keyCode, !held, !others else { return .cancel }
        if now - pressedAt >= minimumHold { return .finish }
        tappedAt = now
        return .cancel
    }

    public mutating func keyDown() -> Action? {
        tappedAt = nil
        guard pressedAt != nil else { return nil }
        pressedAt = nil
        return .cancel
    }
}

/// How a dictation goes into another app. The rules are Hex's.
public enum DictationText {
    /// One synthetic key event when typing instead of pasting.
    public enum Stroke: Sendable, Equatable { case text([UInt16]), lineBreak }

    /// `next` as it should land right after `previous`, with a space when the two would otherwise run together.
    public static func joined(after previous: String, _ next: String) -> String {
        guard let last = previous.last, let first = next.first, !last.isWhitespace, !"([{".contains(last),
              !first.isWhitespace, !",.?!;:)]}".contains(first) else { return next }
        return " " + next
    }

    /// Chromium 155 and 156 on macOS can drop a ⌘V that races their pasteboard notification, however long the wait
    /// first (fixed in 157). `frameworkVersions` are the folders in the app's framework `Versions`; any version present
    /// counts, so a staged update is covered, and Electron's `A` never matches.
    public static func losesPaste(frameworkVersions: [String]) -> Bool {
        frameworkVersions.contains { version in
            let parts = version.split(separator: ".", omittingEmptySubsequences: false)
            return parts.count == 4 && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
                && (parts[0] == "155" || parts[0] == "156")
        }
    }

    /// `text` as key events of at most 20 UTF-16 units, never splitting a character. Line breaks stay their own stroke,
    /// so they can go as Shift-Return and not send a chat message.
    public static func strokes(_ text: String) -> [Stroke] {
        var strokes: [Stroke] = []
        var units: [UInt16] = []
        func flush() {
            if !units.isEmpty { strokes.append(.text(units)) }
            units = []
        }
        for character in text {
            if character.isNewline {
                flush()
                strokes.append(.lineBreak)
                continue
            }
            let next = Array(String(character).utf16)
            if units.count + next.count > 20 { flush() }
            units += next
        }
        flush()
        return strokes
    }
}

/// Push-to-talk dictation: capture while the key is held, then transcribe, clean up and deliver the text. The next
/// dictation can start while the previous one is still processing; deliveries keep the order they were spoken in.
@MainActor @Observable
public final class Dictation {
    /// One finishing capture; `cut` is what it had heard if a new press ended its tail early.
    private final class Tail { var cut: [Float]? }

    public enum Phase: Sendable, Equatable { case idle, listening, transcribing, cleaning }

    /// Listening wins; otherwise the stage of the dictation being processed.
    public var phase: Phase { source != nil && tailing == nil ? .listening : processing > 0 ? stage : .idle }
    /// The microphone's RMS level just now, for a meter.
    @ObservationIgnored public private(set) var level: Float = 0
    /// Keeps capturing this long after the release, so the last word isn't clipped, and up to three times as long
    /// while speech is still running (Hex's 200 ms, growing to 600 ms).
    @ObservationIgnored public var tail: Duration = .milliseconds(200)

    private var source: (any AudioSource)?
    private var processing = 0
    private var stage = Phase.transcribing
    @ObservationIgnored private let capture: () throws -> any AudioSource
    @ObservationIgnored private let engine: () async throws -> any TranscriptionEngine
    @ObservationIgnored private let clean: (String) async -> String
    @ObservationIgnored private let deliver: (String) -> Void
    @ObservationIgnored private var collected: [Float] = []
    @ObservationIgnored private var pump: Task<Void, Never>?
    @ObservationIgnored private var loading: Task<any TranscriptionEngine, any Error>?
    /// The last dictation in line; the next one waits for it so pastes keep their order.
    @ObservationIgnored private var queue: Task<Void, Never>?
    /// Bumped by `cancel`, so dictations already processing drop their results.
    @ObservationIgnored private var generation = 0
    /// The capture still listening through its tail after the release.
    @ObservationIgnored private var tailing: Tail?

    /// `capture` starts a 48 kHz microphone; `engine` hands out the prepared model; `clean` never fails (it falls
    /// back to its input); `deliver` puts the text where the user is typing.
    public init(capture: @escaping () throws -> any AudioSource, engine: @escaping () async throws -> any TranscriptionEngine,
                clean: @escaping (String) async -> String, deliver: @escaping (String) -> Void) {
        self.capture = capture
        self.engine = engine
        self.clean = clean
        self.deliver = deliver
    }

    /// Starts listening. Ignored while already listening; throws when the microphone fails to start.
    public func start() throws {
        if let tailing { // a press during the tail ends that clip now, so this one isn't lost
            tailing.cut = stopCapture()
            self.tailing = nil
        }
        guard source == nil else { return log.info("Dictation: start ignored, still listening") }
        let source = try capture()
        log.info("Dictation: listening")
        self.source = source
        collected = []
        let engine = engine
        loading = Task { try await engine() } // usually already warm; otherwise it loads while the user speaks
        // The capture ring holds ~5 s, so empty it while the key is held; often enough to drive a meter.
        pump = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard let self, let source = self.source else { return }
                let chunk = source.drain()
                self.collected += chunk
                if !chunk.isEmpty { self.level = (chunk.reduce(0) { $0 + $1 * $1 } / Float(chunk.count)).squareRoot() }
            }
        }
    }

    /// Stops listening and drops every dictation still processing, so none of them is pasted.
    public func cancel() {
        generation += 1
        tailing = nil
        discard()
    }

    /// Stops listening and throws away this capture only; dictations already processing still paste.
    public func discard() {
        guard tailing == nil else { return } // that capture is finishing
        loading?.cancel()
        loading = nil
        _ = stopCapture()
    }

    /// Stops listening, then transcribes, cleans and delivers once the dictations before it are delivered. Returns
    /// the delivered text; nil when nothing was heard, it was cancelled, or it wasn't listening.
    @discardableResult public func finish() async throws -> String? {
        guard source != nil, let loading else {
            log.info("Dictation: finish ignored, not listening")
            return nil
        }
        let id = generation
        self.loading = nil
        processing += 1
        stage = .transcribing
        defer { processing -= 1 }
        let mine = Tail()
        tailing = mine
        let release = ContinuousClock.now
        await wait(for: mine)
        let heardTail = ContinuousClock.now - release
        guard id == generation else { return nil }
        let samples = mine.cut ?? stopCapture()
        if tailing === mine { tailing = nil }
        log.info("Dictation: captured \(samples.count) samples, queued")
        let previous = queue
        let turn = Task { () async throws -> String? in
            _ = await previous?.value
            log.info("Dictation: transcribing")
            guard id == self.generation else { return nil }
            self.stage = .transcribing
            guard let audio = try await Self.prepared(samples, tail: heardTail) else {
                log.info("Dictation: \(samples.count) samples, silent, dropped")
                return nil
            }
            let text: String
            do {
                text = try await loading.value.transcribe(samples: audio).map(\.text).joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } catch where id != self.generation {
                return nil // cancelled while the engine loaded
            }
            // Counts only: the text is the user's.
            log.info("Dictation: \(samples.count) samples, \(text.count) characters heard")
            guard id == self.generation, !text.isEmpty else { return nil }
            self.stage = .cleaning
            let cleaned = await self.clean(text)
            guard id == self.generation else { return nil }
            log.info("Dictation: delivering \(cleaned.count) characters")
            self.deliver(cleaned)
            return cleaned
        }
        queue = Task { _ = await turn.result }
        return try await turn.value
    }

    /// Waits out the tail, past its base length only while the last 160 ms still sound like speech.
    private func wait(for mine: Tail) async {
        let release = ContinuousClock.now
        try? await Task.sleep(for: tail)
        while tailing === mine, let source, ContinuousClock.now - release < tail * 3 {
            collected += source.drain()
            let recent = Array(collected.suffix(Int(0.16 * MicrophoneCapture.sampleRate)))
            guard !Self.isSilent(recent, rate: MicrophoneCapture.sampleRate, floor: 1e-4) else { return } // -40 dBFS
            try? await Task.sleep(for: .milliseconds(40))
        }
    }

    /// True when the loudest 30 ms, offset removed, stays under `floor` (power; 1e-5 is -50 dBFS): an empty hold, which
    /// models fill with an invented "Thank you". The default threshold and the window are Hex's.
    nonisolated static func isSilent(_ samples: [Float], rate: Double, floor: Float = 1e-5) -> Bool {
        let window = Int(rate * 0.03)
        return !stride(from: 0, to: samples.count, by: window).contains { start in
            let slice = samples[start..<min(start + window, samples.count)]
            let mean = slice.reduce(0, +) / Float(slice.count)
            return slice.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Float(slice.count) >= floor
        }
    }

    /// `isSilent`, without the first 250 ms and the tail, where the microphone can hear Meety's own start and stop sounds.
    /// A capture too short for that is treated as heard: better a model's guess than a quick word dropped.
    nonisolated static func heardNothing(_ samples: [Float], rate: Double, tail: Duration) -> Bool {
        let head = Int(rate * 0.25), end = samples.count - Int(rate * Double(tail.components.seconds) + rate * Double(tail.components.attoseconds) * 1e-18)
        guard end - head >= Int(rate * 0.1) else { return samples.isEmpty || isSilent(samples, rate: rate) }
        return isSilent(Array(samples[head..<end]), rate: rate)
    }

    /// `samples` with each long pause cut to its first 2.5 s and last 0.3 s (a trailing one to its first 2.5 s), so a
    /// hands-free dictation left waiting doesn't feed the model the silence it invents text in. Quiet means within 4 dB of
    /// a noise floor that falls at once and rises 3 dB per second, or under -70 dBFS, and never over -35 dBFS. A clip with
    /// nothing above it stays whole. The rules are Hex's, plus that ceiling.
    nonisolated static func cappingPauses(_ samples: [Float], rate: Double) -> [Float] {
        let frame = Int(rate * 0.02), keepHead = Int(rate * 2.5), keepTail = Int(rate * 0.3)
        guard frame > 0 else { return samples }
        var output: [Float] = []
        output.reserveCapacity(samples.count)
        var floor: Float?
        var pause: Range<Int>?
        var heard = false
        func closePause(trailing: Bool) {
            guard let run = pause else { return }
            pause = nil
            if run.count <= keepHead + (trailing ? 0 : keepTail) {
                output += samples[run]
            } else {
                output += samples[run.lowerBound..<(run.lowerBound + keepHead)]
                if !trailing { output += samples[(run.upperBound - keepTail)..<run.upperBound] }
            }
        }
        for start in stride(from: 0, to: samples.count, by: frame) {
            let end = min(start + frame, samples.count)
            let slice = samples[start..<end]
            let mean = slice.reduce(0, +) / Float(slice.count)
            let power = slice.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Float(slice.count)
            let level = 10 * log10(max(power, 1e-12))
            let bottom = floor.map { min(level, $0 + 0.06) } ?? level // 0.06 dB a frame is 3 dB a second
            floor = bottom
            if level < -35, level <= max(bottom + 4, -70) { // the ceiling: a clip that starts mid-word starts the floor high
                pause = (pause?.lowerBound ?? start)..<end
            } else {
                heard = true
                closePause(trailing: false)
                output += slice
            }
        }
        guard heard else { return samples }
        closePause(trailing: true)
        return output
    }

    /// The capture at the model's rate, or nil when it's silent. Off the main actor: a hands-free capture can be long.
    @concurrent private static func prepared(_ samples: [Float], tail: Duration) async throws -> [Float]? {
        guard !heardNothing(samples, rate: MicrophoneCapture.sampleRate, tail: tail) else { return nil }
        return try Resampler(from: MicrophoneCapture.sampleRate, to: transcriptionSampleRate)
            .process(cappingPauses(samples, rate: MicrophoneCapture.sampleRate))
    }

    /// Stops the microphone and returns everything it captured.
    private func stopCapture() -> [Float] {
        pump?.cancel()
        pump = nil
        level = 0
        guard let source else { return [] }
        self.source = nil
        source.stop()
        var samples = collected
        collected = []
        while case let chunk = source.drain(), !chunk.isEmpty { samples += chunk }
        return samples
    }
}
