import Foundation
import Observation

/// App preferences in UserDefaults. The first launch imports the Tauri store files
/// (`recording_preferences.json`, `preferences.json`, `onboarding-status.json`); later edits live only here.
@MainActor @Observable
public final class Settings {
    @ObservationIgnored private let defaults: UserDefaults

    /// Transcription language: "auto", "en", "tl", or another Whisper code.
    public var language: String { didSet { defaults.set(language, forKey: "language") } }
    public var saveFolder: URL { didSet { defaults.set(saveFolder.path, forKey: "saveFolder") } }
    public var preferredMicDevice: String? { didSet { defaults.set(preferredMicDevice, forKey: "preferredMicDevice") } }
    public var preferredSystemDevice: String? { didSet { defaults.set(preferredSystemDevice, forKey: "preferredSystemDevice") } }
    /// Capture other apps' audio (the global process tap). There is no device to pick, only on or off.
    public var recordSystemAudio: Bool { didSet { defaults.set(recordSystemAudio, forKey: "recordSystemAudio") } }
    /// The "inform participants" notice shown when recording starts.
    public var showRecordingConsent: Bool { didSet { defaults.set(showRecordingConsent, forKey: "showRecordingConsent") } }
    public var recordingNotifications: Bool { didSet { defaults.set(recordingNotifications, forKey: "recordingNotifications") } }
    public var summaryNotifications: Bool { didSet { defaults.set(summaryNotifications, forKey: "summaryNotifications") } }
    public var autoSummary: Bool { didSet { defaults.set(autoSummary, forKey: "autoSummary") } }
    /// Summary output language code; nil follows the transcript.
    public var summaryLanguage: String? { didSet { defaults.set(summaryLanguage, forKey: "summaryLanguage") } }
    public var onboardingCompleted: Bool { didSet { defaults.set(onboardingCompleted, forKey: "onboardingCompleted") } }
    public var builtInSummaryModel: String? { didSet { defaults.set(builtInSummaryModel, forKey: "builtInSummaryModel") } }
    /// Hold Right Option to dictate into any app.
    public var dictationEnabled: Bool { didSet { defaults.set(dictationEnabled, forKey: "dictationEnabled") } }
    /// `CleanupMode` raw value: off, onDevice, summaryModel or dictationModel.
    public var dictationCleanup: String { didSet { defaults.set(dictationCleanup, forKey: "dictationCleanup") } }
    /// The `Provider` raw value and model name for the dictationModel cleanup; its key is the provider's Keychain entry.
    public var dictationProvider: String { didSet { defaults.set(dictationProvider, forKey: "dictationProvider") } }
    public var dictationModel: String { didSet { defaults.set(dictationModel, forKey: "dictationModel") } }
    /// Keep pasted dictations in the database for seven days. Off by default: dictated text stays out of files unless asked.
    public var dictationHistory: Bool { didSet { defaults.set(dictationHistory, forKey: "dictationHistory") } }
    /// How cleanup should write for particular apps.
    public var dictationAppPrompts: [DictationAppPrompt] {
        didSet { defaults.set(try? JSONEncoder().encode(dictationAppPrompts), forKey: "dictationAppPrompts") }
    }
    /// `DictationKey` raw value.
    public var dictationKey: String { didSet { defaults.set(dictationKey, forKey: "dictationKey") } }
    /// One term per line, as `DictationVocabulary` reads it.
    public var dictationVocabulary: String { didSet { defaults.set(dictationVocabulary, forKey: "dictationVocabulary") } }

    public static let defaultSaveFolder = URL.moviesDirectory.appending(path: "meety-recordings", directoryHint: .isDirectory)

    public init(defaults: UserDefaults = .standard, importFrom tauriDir: URL = Paths.appSupport) {
        self.defaults = defaults
        if !defaults.bool(forKey: "importedTauriStores") {
            Self.importTauriStores(from: tauriDir, into: defaults)
            defaults.set(true, forKey: "importedTauriStores")
        }
        language = defaults.string(forKey: "language") ?? "auto"
        saveFolder = defaults.string(forKey: "saveFolder").map { URL(fileURLWithPath: $0, isDirectory: true) } ?? Self.defaultSaveFolder
        preferredMicDevice = defaults.string(forKey: "preferredMicDevice")
        preferredSystemDevice = defaults.string(forKey: "preferredSystemDevice")
        recordSystemAudio = defaults.object(forKey: "recordSystemAudio") as? Bool ?? true
        showRecordingConsent = defaults.object(forKey: "showRecordingConsent") as? Bool ?? true
        recordingNotifications = defaults.object(forKey: "recordingNotifications") as? Bool ?? true
        summaryNotifications = defaults.object(forKey: "summaryNotifications") as? Bool ?? true
        autoSummary = defaults.object(forKey: "autoSummary") as? Bool ?? true
        summaryLanguage = defaults.string(forKey: "summaryLanguage")
        onboardingCompleted = defaults.bool(forKey: "onboardingCompleted")
        builtInSummaryModel = defaults.string(forKey: "builtInSummaryModel")
        dictationEnabled = defaults.bool(forKey: "dictationEnabled")
        dictationCleanup = defaults.string(forKey: "dictationCleanup") ?? "onDevice"
        dictationProvider = defaults.string(forKey: "dictationProvider") ?? "claude"
        dictationModel = defaults.string(forKey: "dictationModel") ?? ""
        dictationHistory = defaults.bool(forKey: "dictationHistory")
        dictationAppPrompts = defaults.data(forKey: "dictationAppPrompts").flatMap { try? JSONDecoder().decode([DictationAppPrompt].self, from: $0) } ?? []
        dictationKey = defaults.string(forKey: "dictationKey") ?? "rightOption"
        dictationVocabulary = defaults.string(forKey: "dictationVocabulary") ?? ""
    }

    private static func importTauriStores(from dir: URL, into defaults: UserDefaults) {
        func json(_ name: String) -> [String: Any]? {
            guard let data = try? Data(contentsOf: dir.appending(path: name)) else { return nil }
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }
        if let prefs = json("recording_preferences.json")?["preferences"] as? [String: Any] {
            if let folder = prefs["save_folder"] as? String, !folder.isEmpty { defaults.set(folder, forKey: "saveFolder") }
            if let mic = prefs["preferred_mic_device"] as? String { defaults.set(mic, forKey: "preferredMicDevice") }
            if let system = prefs["preferred_system_device"] as? String { defaults.set(system, forKey: "preferredSystemDevice") }
        }
        if let show = json("preferences.json")?["show_recording_notification"] as? Bool {
            defaults.set(show, forKey: "showRecordingConsent")
        }
        if let status = json("onboarding-status.json")?["status"] as? [String: Any] {
            if let completed = status["completed"] as? Bool { defaults.set(completed, forKey: "onboardingCompleted") }
            if let model = (status["model_status"] as? [String: Any])?["selected_summary_model"] as? String {
                defaults.set(model, forKey: "builtInSummaryModel")
            }
        }
        // shortcut: notifications.json (~/Library/Application Support/meetily) is not imported; its defaults match ours.
    }
}

/// The user's instructions for dictating into one app.
public struct DictationAppPrompt: Codable, Sendable, Equatable {
    public var bundleID: String
    public var name: String
    public var instructions: String

    public init(bundleID: String, name: String, instructions: String) {
        self.bundleID = bundleID
        self.name = name
        self.instructions = instructions
    }
}
