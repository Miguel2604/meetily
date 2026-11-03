import AppKit
import Audio
import Core
import Observation
import Summary
import Transcription

/// App-wide state the windows observe: the store, preferences, the meetings list and the content route.
@Observable
final class AppModel {
    enum Route: Hashable { case home, meeting(String) }

    let store: Store
    let settings: Settings
    let recorder: Recorder
    let parakeet = ParakeetModels(directory: Paths.parakeetModels)
    let whisper = WhisperModels(directory: Paths.whisperModels)
    let builtIn = BuiltInModels(directory: Paths.summaryModels)
    @ObservationIgnored private(set) lazy var summaries = SummaryService(store: store, builtIn: builtIn)
    /// The summary template picked last in this session.
    @ObservationIgnored var summaryTemplate = "standard_meeting"
    private(set) var meetings: [Meeting] = []
    var route: Route = .home
    @ObservationIgnored private var voice: VoiceModel?

    init(store: Store, settings: Settings) {
        self.store = store
        self.settings = settings
        recorder = Recorder(store: store)
    }

    // MARK: Recording

    struct RecordingError: Error, CustomStringConvertible { var description: String }

    func startRecording() async {
        route = .home
        await recorder.start { report in try await prepareRecording(report) }
    }

    func stopRecording() async {
        guard let id = await recorder.stop() else { return }
        await reloadMeetings()
        route = .meeting(id)
    }

    /// Permission, the transcription engine, voice detection, then the captures (useRecordingStart.ts).
    private func prepareRecording(_ report: (String) -> Void) async throws -> Recorder.Inputs {
        let title = Self.defaultTitle()
        #if DEBUG
        if DemoRecording.isRequested { return DemoRecording.inputs(title: title, folder: Paths.meetingFolder(base: settings.saveFolder, name: title)) }
        #endif
        if MicrophonePermission.isUndetermined {
            report("Waiting for microphone permission…")
            _ = await MicrophonePermission.request()
        }
        let useMicrophone = MicrophonePermission.isGranted
        guard useMicrophone || settings.recordSystemAudio else {
            throw RecordingError(description: "Microphone access is off. Allow Meety in System Settings › Privacy & Security › Microphone.")
        }

        report("Loading transcription model…")
        let engine: any TranscriptionEngine
        do {
            switch EngineChoice.route(language: settings.language, config: try await store.transcriptConfig()) {
            case .parakeet(let model): engine = try await parakeet.engine(model)
            case .whisper(let model, let language): engine = try await whisper.engine(model, language: language)
            }
        } catch {
            throw RecordingError(description: "Transcription model not ready: \(error). Download it in Settings › Transcription.")
        }
        report("Loading voice detection…")
        let detector = try await voiceDetector()

        report("Starting audio capture…")
        let (notices, noticeSink) = AsyncStream.makeStream(of: String.self)
        let microphone = useMicrophone ? try LiveMicrophone(preferred: settings.preferredMicDevice) : nil
        if let microphone { Task { for await notice in microphone.notices { noticeSink.yield(notice) } } }
        if !useMicrophone { noticeSink.yield("Microphone access is off. Recording system audio only.") }
        var system: SystemAudioCapture?
        if settings.recordSystemAudio {
            let capture = SystemAudioCapture()
            do { try capture.start(); system = capture } catch { noticeSink.yield("System audio unavailable: \(error)") }
        }
        guard microphone?.device != nil || system != nil else {
            microphone?.stop()
            throw RecordingError(description: "No microphone or system audio available to record.")
        }
        return Recorder.Inputs(
            title: title, folder: Paths.meetingFolder(base: settings.saveFolder, name: title), engine: engine,
            detector: detector, microphone: microphone, system: system,
            microphoneName: microphone?.device?.name, systemName: system == nil ? nil : "System audio", notices: notices)
    }

    /// A fresh Silero stream; the model loads (and downloads, ~2 MB) once.
    func voiceDetector() async throws -> any VoiceDetector {
        if voice == nil { voice = try await VoiceModel.load(directory: Paths.models.appending(path: "vad")) }
        guard let voice else { throw RecordingError(description: "Voice detection failed to load.") }
        return voice.detector()
    }

    /// `Meeting dd_MM_yy_HH_mm_ss`, as the web app named new recordings.
    static func defaultTitle(_ date: Date = Date()) -> String {
        date.formatted(Date.VerbatimFormatStyle(
            format: "Meeting \(day: .twoDigits)_\(month: .twoDigits)_\(year: .twoDigits)_\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased))_\(minute: .twoDigits)_\(second: .twoDigits)",
            timeZone: .current, calendar: Calendar(identifier: .gregorian)))
    }

    // MARK: Meetings

    func reloadMeetings() async {
        do { meetings = try await store.meetings() } catch { present(error) }
    }

    func rename(_ id: String, to title: String) async {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        do { _ = try await store.renameMeeting(id: id, title: title) } catch { present(error) }
        await reloadMeetings()
    }

    /// Removes the meeting from the database; its recording folder stays on disk, as in the Tauri app.
    func delete(_ id: String) async {
        do { _ = try await store.deleteMeeting(id: id) } catch { present(error) }
        if route == .meeting(id) { route = .home }
        await reloadMeetings()
    }

    func present(_ error: Error) {
        let alert = NSAlert(error: error)
        if let window = NSApp.mainWindow { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }
}

/// Runs `body` now and again after any observed property it read changes (Observation without SwiftUI).
func track(_ body: @escaping @MainActor () -> Void) {
    withObservationTracking(body) { Task { @MainActor in track(body) } }
}
