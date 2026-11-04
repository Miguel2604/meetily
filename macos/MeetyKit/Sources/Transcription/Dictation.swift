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

/// Push-to-talk dictation: capture while the key is held, then transcribe, clean up and deliver the text. The next
/// dictation can start while the previous one is still processing; deliveries keep the order they were spoken in.
@MainActor @Observable
public final class Dictation {
    public enum Phase: Sendable, Equatable { case idle, listening, transcribing, cleaning }

    /// Listening wins; otherwise the stage of the dictation being processed.
    public var phase: Phase { source != nil ? .listening : processing > 0 ? stage : .idle }
    /// Keeps capturing this long after the release, so the last word isn't clipped.
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
        guard source == nil else { return }
        let source = try capture()
        self.source = source
        collected = []
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

    /// Stops listening and drops every dictation still processing, so none of them is pasted.
    public func cancel() {
        generation += 1
        loading?.cancel()
        loading = nil
        _ = stopCapture()
    }

    /// Stops listening, then transcribes, cleans and delivers once the dictations before it are delivered. Returns
    /// the delivered text; nil when nothing was heard, it was cancelled, or it wasn't listening.
    @discardableResult public func finish() async throws -> String? {
        guard source != nil, let loading else { return nil }
        let id = generation
        self.loading = nil
        processing += 1
        stage = .transcribing
        defer { processing -= 1 }
        try? await Task.sleep(for: tail)
        guard id == generation else { return nil }
        let samples = stopCapture()
        let previous = queue
        let turn = Task { () async throws -> String? in
            _ = await previous?.value
            guard id == self.generation else { return nil }
            self.stage = .transcribing
            let audio = try Resampler(from: MicrophoneCapture.sampleRate, to: transcriptionSampleRate).process(samples)
            let text: String
            do {
                text = try await loading.value.transcribe(samples: audio).map(\.text).joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } catch where id != self.generation {
                return nil // cancelled while the engine loaded
            }
            guard id == self.generation, !text.isEmpty else { return nil }
            self.stage = .cleaning
            let cleaned = await self.clean(text)
            guard id == self.generation else { return nil }
            self.deliver(cleaned)
            return cleaned
        }
        queue = Task { _ = await turn.result }
        return try await turn.value
    }

    /// Stops the microphone and returns everything it captured.
    private func stopCapture() -> [Float] {
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
