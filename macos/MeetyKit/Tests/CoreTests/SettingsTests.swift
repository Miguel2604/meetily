import Foundation
import Testing
@testable import Core
import GRDB

@MainActor @Suite struct SettingsTests {
    let defaults: UserDefaults
    let dir: URL

    init() throws {
        defaults = UserDefaults(suiteName: "meety-tests-\(UUID().uuidString)")!
        dir = FileManager.default.temporaryDirectory.appending(path: "meety-settings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    func write(_ name: String, _ json: String) throws {
        try Data(json.utf8).write(to: dir.appending(path: name))
    }

    @Test func `defaults when nothing was imported`() {
        let settings = Settings(defaults: defaults, importFrom: dir)
        #expect(settings.language == "auto")
        #expect(settings.saveFolder.path == URL.moviesDirectory.appending(path: "meety-recordings").path)
        #expect(settings.showRecordingConsent)
        #expect(settings.recordingNotifications)
        #expect(!settings.onboardingCompleted)
        #expect(settings.preferredMicDevice == nil)
    }

    @Test func `imports the Tauri store files once`() throws {
        try write("recording_preferences.json", #"{"preferences":{"save_folder":"/tmp/rec","auto_save":false,"file_format":"mp4","preferred_mic_device":"MacBook Pro Microphone","preferred_system_device":null,"system_audio_backend":"coreaudio"}}"#)
        try write("preferences.json", #"{"show_recording_notification":false}"#)
        try write("onboarding-status.json", #"{"status":{"completed":true,"current_step":4,"version":"1.0","last_updated":"x","model_status":{"parakeet":"downloaded","summary":"downloaded","selected_summary_model":"qwen3.5:4b"}}}"#)
        let settings = Settings(defaults: defaults, importFrom: dir)
        #expect(settings.saveFolder.path == "/tmp/rec")
        #expect(settings.preferredMicDevice == "MacBook Pro Microphone")
        #expect(!settings.showRecordingConsent)
        #expect(settings.onboardingCompleted)
        #expect(settings.builtInSummaryModel == "qwen3.5:4b")

        // Later edits win over the files: the import does not run again.
        settings.saveFolder = URL(fileURLWithPath: "/tmp/elsewhere")
        let again = Settings(defaults: defaults, importFrom: dir)
        #expect(again.saveFolder.path == "/tmp/elsewhere")
    }

    @Test func `malformed files fall back to defaults`() throws {
        try write("recording_preferences.json", "{not json")
        let settings = Settings(defaults: defaults, importFrom: dir)
        #expect(settings.saveFolder.path == URL.moviesDirectory.appending(path: "meety-recordings").path)
    }
}

@Suite struct PathsTests {
    @Test(arguments: [
        ("Team: Standup?", "Team_ Standup_"),
        ("  a/b\\c  ", "a_b_c"),
        ("x*y\"z<w>|v", "x_y_z_w__v"),
        ("tab\there", "tab_here"),
        ("Plain name", "Plain name"),
    ])
    func `sanitize filename matches the Rust port`(input: String, expected: String) {
        #expect(Paths.sanitizeFilename(input) == expected)
    }

    @Test func `meeting folder is name plus UTC minute`() {
        let date = Date(timeIntervalSince1970: 1_762_177_800) // 2025-11-03 13:50:00 UTC
        let url = Paths.meetingFolder(base: URL(fileURLWithPath: "/rec"), name: "Daily: sync", date: date)
        #expect(url.path == "/rec/Daily_ sync_2025-11-03_13-50")
    }
}

@Suite struct KeychainTests {
    let keychain = Keychain(service: "com.meetily.ai.tests.\(UUID().uuidString)")

    @Test func `store, read, replace and delete a key`() throws {
        #expect(keychain.get("openai") == nil)
        try keychain.set("sk-1", for: "openai")
        #expect(keychain.get("openai") == "sk-1")
        try keychain.set("sk-2", for: "openai")
        #expect(keychain.get("openai") == "sk-2")
        try keychain.set(nil, for: "openai")
        #expect(keychain.get("openai") == nil)
    }

    @Test func `imports provider keys from the settings row once`() async throws {
        let store = try tempStore()
        try await store.saveModelConfig(provider: "openai", model: "gpt", whisperModel: "large-v3", ollamaEndpoint: nil)
        try await store.pool.write {
            try $0.execute(sql: "UPDATE settings SET openaiApiKey = 'sk-a', anthropicApiKey = 'ant', customOpenAIConfig = ?",
                           arguments: [#"{"endpoint":"http://x","apiKey":"custom-k","model":"m"}"#])
        }
        let imported = try await keychain.importKeys(from: store)
        #expect(imported == 3)
        #expect(keychain.get("openai") == "sk-a")
        #expect(keychain.get("claude") == "ant")
        #expect(keychain.get("custom-openai") == "custom-k")
        #expect(keychain.get("groq") == nil)
        // D10: the database columns are left alone.
        let column = try await store.pool.read { try String.fetchOne($0, sql: "SELECT openaiApiKey FROM settings") }
        #expect(column == "sk-a")
        for p in ["openai", "claude", "custom-openai"] { try keychain.set(nil, for: p) }
    }
}
