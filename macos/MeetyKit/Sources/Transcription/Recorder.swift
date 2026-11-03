import Audio
import Core
import Foundation
import Observation

/// The recording screen's state: start (with progress), pause, live segments, warnings, stop and save.
/// The app supplies the engine and captures through `start`'s `prepare` closure.
@MainActor @Observable
public final class Recorder {
    public enum Phase: Sendable, Equatable {
        case idle
        case starting(String)
        case recording
        case paused
        case stopping
        case failed(String)
    }

    public struct Inputs {
        public var title: String
        public var folder: URL
        public var engine: any TranscriptionEngine
        public var detector: any VoiceDetector
        public var microphone: (any AudioSource)?
        public var system: (any AudioSource)?
        public var microphoneName: String?
        public var systemName: String?
        /// Device changes and other capture messages to show as warnings.
        public var notices: AsyncStream<String>?

        public init(title: String, folder: URL, engine: any TranscriptionEngine, detector: any VoiceDetector,
                    microphone: (any AudioSource)?, system: (any AudioSource)?, microphoneName: String? = nil,
                    systemName: String? = nil, notices: AsyncStream<String>? = nil) {
            self.title = title; self.folder = folder; self.engine = engine; self.detector = detector
            self.microphone = microphone; self.system = system
            self.microphoneName = microphoneName; self.systemName = systemName; self.notices = notices
        }
    }

    public private(set) var phase = Phase.idle
    /// Editable while recording; the meeting is saved under the latest value.
    public var title = ""
    public private(set) var segments: [LiveSegment] = []
    /// The latest warning (dropped audio, falling behind, device switched).
    public private(set) var notice: String?
    public private(set) var startedAt: Date?

    @ObservationIgnored private let store: Store
    @ObservationIgnored private var session: RecordingSession?
    @ObservationIgnored private var listeners: [Task<Void, Never>] = []
    @ObservationIgnored private var pausedTotal: TimeInterval = 0
    @ObservationIgnored private var pausedAt: Date?

    public init(store: Store) { self.store = store }

    public var isActive: Bool { session != nil }

    /// Meter levels, read at display rate.
    public var levels: (microphone: AudioLevel, system: AudioLevel) {
        session?.levels.withLock { $0 } ?? (.silent, .silent)
    }

    /// Recorded time so far, without pauses.
    public func elapsed(at now: Date = Date()) -> TimeInterval {
        guard let startedAt else { return 0 }
        return max(0, now.timeIntervalSince(startedAt) - pausedTotal - (pausedAt.map { now.timeIntervalSince($0) } ?? 0))
    }

    /// `prepare` loads the model and starts the captures, reporting each step.
    public func start(_ prepare: (_ report: (String) -> Void) async throws -> Inputs) async {
        switch phase { case .idle, .failed: break; default: return }
        phase = .starting("Preparing…")
        segments = []
        notice = nil
        do {
            let inputs = try await prepare { self.phase = .starting($0) }
            let session: RecordingSession
            do {
                session = try RecordingSession(
                    title: inputs.title, folder: inputs.folder, store: store, engine: inputs.engine, detector: inputs.detector,
                    microphone: inputs.microphone, system: inputs.system,
                    microphoneName: inputs.microphoneName, systemName: inputs.systemName)
            } catch {
                inputs.microphone?.stop()
                inputs.system?.stop()
                throw error
            }
            title = inputs.title
            self.session = session
            listeners = [Task { [weak self] in
                for await event in session.events {
                    switch event {
                    case .segment(let segment): self?.segments.append(segment)
                    case .warning(let message): self?.notice = message
                    case .saved: break
                    }
                }
            }]
            if let notices = inputs.notices {
                listeners.append(Task { [weak self] in for await message in notices { self?.notice = message } })
            }
            await session.start()
            startedAt = Date()
            pausedTotal = 0
            pausedAt = nil
            phase = .recording
        } catch {
            phase = .failed(String(describing: error))
        }
    }

    public func pause() async {
        guard phase == .recording, let session else { return }
        await session.pause()
        pausedAt = Date()
        phase = .paused
    }

    public func resume() async {
        guard phase == .paused, let session else { return }
        await session.resume()
        if let pausedAt { pausedTotal += Date().timeIntervalSince(pausedAt) }
        pausedAt = nil
        phase = .recording
    }

    /// Drains transcription, saves the meeting (renamed if the title was edited) and returns its id.
    public func stop() async -> String? {
        guard let session, phase == .recording || phase == .paused else { return nil }
        phase = .stopping
        defer {
            listeners.forEach { $0.cancel() }
            listeners = []
            self.session = nil
            startedAt = nil
        }
        do {
            let id = try await session.stop()
            await listeners.first?.value // the event stream ends on save, so every segment is in
            let edited = title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !edited.isEmpty, edited != (try await store.meeting(id: id))?.title {
                _ = try await store.renameMeeting(id: id, title: edited)
            }
            phase = .idle
            return id
        } catch {
            phase = .failed("Failed to save the recording: \(error)")
            return nil
        }
    }
}
