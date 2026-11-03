import AppKit
import Core

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel?
    private var mainWindow: MainWindowController?
    private var settingsWindow: SettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.make()
        let store: Store
        do {
            try FileManager.default.createDirectory(at: Paths.appSupport, withIntermediateDirectories: true)
            store = try Store()
        } catch {
            NSAlert(error: error).runModal()
            NSApp.terminate(nil)
            return
        }
        // A dev run on a copy of the data (MEETY_DATA_DIR) keeps its preferences out of the real domain.
        let devRun = ProcessInfo.processInfo.environment["MEETY_DATA_DIR"] != nil
        let defaults = devRun ? UserDefaults(suiteName: "com.meetily.ai.dev")! : .standard
        let model = AppModel(store: store, settings: Settings(defaults: defaults))
        let main = MainWindowController(model: model)
        main.showWindow(nil)
        self.model = model
        mainWindow = main
        Task { await model.reloadMeetings() }
        Task { _ = try? await Keychain().importKeys(from: store) } // D10: plaintext columns stay until cutover
        NSApp.activate()
        #if DEBUG
        DebugSnapshot.scheduleIfRequested { [weak self] in self?.settingsWindow?.window ?? main.window }
        if DemoRecording.isRequested { Task { await model.startRecording() } }
        if let id = ProcessInfo.processInfo.environment["MEETY_OPEN_MEETING"] { model.route = .meeting(id) }
        if let tab = ProcessInfo.processInfo.environment["MEETY_SETTINGS_TAB"].flatMap(Int.init).flatMap(SettingsWindowController.Tab.init) {
            showSettings(tab: tab)
        }
        #endif
    }

    @objc func showSettings(_ sender: Any?) { showSettings(tab: nil) }

    func showSettings(tab: SettingsWindowController.Tab?) {
        guard let model else { return }
        if settingsWindow == nil { settingsWindow = SettingsWindowController(model: model) }
        settingsWindow?.show(tab)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { mainWindow?.showWindow(nil) }
        return true
    }
}
