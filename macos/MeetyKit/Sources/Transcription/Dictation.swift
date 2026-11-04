import Audio
import Foundation
import Observation

/// Hold-to-talk on one modifier key held alone (Right Option by default), fed from the app's key monitors.
/// Typing or another modifier during the hold is a keyboard shortcut, so it cancels.
public struct PushToTalk: Sendable {
    public enum Action: Sendable, Equatable { case start, finish, cancel }

    /// Virtual key code of the trigger; 61 is Right Option.
    public let keyCode: UInt16
    /// Shorter holds are taps, not dictation.
    public let minimumHold: Duration
    private var pressedAt: ContinuousClock.Instant?

    public init(keyCode: UInt16 = 61, minimumHold: Duration = .milliseconds(300)) {
        self.keyCode = keyCode
        self.minimumHold = minimumHold
    }

    /// A modifier changed. `held`: the trigger is down; `others`: any other modifier is down.
    public mutating func flagsChanged(keyCode: UInt16, held: Bool, others: Bool, at now: ContinuousClock.Instant) -> Action? {
        guard let pressedAt else {
            guard keyCode == self.keyCode, held, !others else { return nil }
            self.pressedAt = now
            return .start
        }
        self.pressedAt = nil
        guard keyCode == self.keyCode, !held, !others else { return .cancel }
        return now - pressedAt >= minimumHold ? .finish : .cancel
    }

    public mutating func keyDown() -> Action? {
        guard pressedAt != nil else { return nil }
        pressedAt = nil
        return .cancel
    }
}

/// One dictation at a time: capture while the key is held, then transcribe, clean up and deliver the text.
@MainActor @Observable
public final class Dictation {
    public enum Phase: Sendable, Equatable { case idle, listening, transcribing, cleaning }

    public private(set) var phase = Phase.idle
    /// Keeps capturing this long after the release, so the last word isn't clipped.
    @ObservationIgnored public var tail: Duration = .milliseconds(200)

    @ObservationIgnored private let capture: () throws -> any AudioSource
    @ObservationIgnored private let engine: () async throws -> any TranscriptionEngine
    @ObservationIgnored private let clean: (String) async -> String
    @ObservationIgnored private let deliver: (String) -> Void
    @ObservationIgnored private var source: (any AudioSource)?
    @ObservationIgnored private var collected: [Float] = []
    @ObservationIgnored private var pump: Task<Void, Never>?
    @ObservationIgnored private var loading: Task<any TranscriptionEngine, any Error>?

    /// `capture` starts a 48 kHz microphone; `engine` hands out the prepared model; `clean` never fails (it falls
    /// back to its input); `deliver` puts the text where the user is typing.
    public init(capture: @escaping () throws -> any AudioSource, engine: @escaping () async throws -> any TranscriptionEngine,
                clean: @escaping (String) async -> String, deliver: @escaping (String) -> Void) {
        self.capture = capture
        self.engine = engine
        self.clean = clean
        self.deliver = deliver
    }

    /// Starts listening. Ignored unless idle; throws when the microphone fails to start.
    public func start() throws {
        guard phase == .idle else { return }
        let source = try capture()
        self.source = source
        collected = []
        phase = .listening
        let engine = engine
        loading = Task { try await engine() } // usually already warm; otherwise it loads while the user speaks
        // The capture ring holds ~5 s, so empty it while the key is held.
        pump = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, let source = self.source else { return }
                self.collected += source.drain()
            }
        }
    }

    public func cancel() {
        guard phase == .listening else { return }
        stopCapture()
        loading?.cancel()
        loading = nil
        phase = .idle
    }

    /// Stops listening, then transcribes, cleans and delivers. Returns the delivered text; nil when nothing was heard
    /// or it wasn't listening.
    @discardableResult public func finish() async throws -> String? {
        guard phase == .listening, let loading else { return nil }
        phase = .transcribing
        defer { phase = .idle; self.loading = nil }
        try? await Task.sleep(for: tail)
        let samples = stopCapture()
        let audio = try Resampler(from: MicrophoneCapture.sampleRate, to: transcriptionSampleRate).process(samples)
        let text = try await loading.value.transcribe(samples: audio).map(\.text).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        phase = .cleaning
        let cleaned = await clean(text)
        deliver(cleaned)
        return cleaned
    }

    /// Stops the microphone and returns everything it captured.
    @discardableResult private func stopCapture() -> [Float] {
        pump?.cancel()
        pump = nil
        guard let source else { return [] }
        self.source = nil
        source.stop()
        var samples = collected
        collected = []
        while case let chunk = source.drain(), !chunk.isEmpty { samples += chunk }
        return samples
    }
}
