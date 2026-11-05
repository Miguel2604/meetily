import AppKit
import Core
import os

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel?
    private var mainWindow: MainWindowController?
    private var settingsWindow: SettingsWindowController?
    private var onboarding: OnboardingWindowController?
    private var statusItem: StatusItem?
    private var quitting = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.make()
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleQuitEvent(_:reply:)),
                                                     forEventClass: AEEventClass(kCoreEventClass), andEventID: AEEventID(kAEQuitApplication))
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
        self.model = model
        mainWindow = main
        var needsOnboarding = !model.settings.onboardingCompleted
        #if DEBUG
        if ProcessInfo.processInfo.environment["MEETY_ONBOARDING"] != nil { needsOnboarding = true }
        #endif
        if needsOnboarding {
            onboarding = OnboardingWindowController(model: model) { [weak self] in
                self?.onboarding?.close()
                self?.onboarding = nil
                self?.mainWindow?.showWindow(nil)
            }
            onboarding?.showWindow(nil)
        } else {
            main.showWindow(nil)
        }
        Task { await model.reloadMeetings() }
        statusItem = StatusItem(model: model) { [weak self] in self?.showMainWindow(nil) }
        _ = model.dictation
        model.notifier.openMeeting = { [weak self, weak model] id in
            self?.showMainWindow(nil)
            model?.route = .meeting(id)
        }
        var importKeys = true
        #if DEBUG
        importKeys = !DebugSnapshot.isActive
        #endif
        if importKeys { Task { _ = try? await Keychain().importKeys(from: store) } } // D10: plaintext columns stay until cutover
        NSApp.activate()
        DispatchQueue.main.async { Self.logLaunchTime() }
        #if DEBUG
        DebugSnapshot.scheduleIfRequested { [weak self] in self?.settingsWindow?.window ?? self?.onboarding?.window ?? main.window?.attachedSheet ?? main.window }
        if DemoRecording.isRequested { Task { await model.startRecording() } }
        if let frames = ProcessInfo.processInfo.environment["MEETY_DICTATION_PILL"] { model.dictation.runPillDemo(frames: frames) }
        if let id = ProcessInfo.processInfo.environment["MEETY_OPEN_MEETING"] { model.route = .meeting(id) }
        if let path = ProcessInfo.processInfo.environment["MEETY_IMPORT"] { main.importFile(URL(fileURLWithPath: path)) }
        if let tab = ProcessInfo.processInfo.environment["MEETY_SETTINGS_TAB"].flatMap(Int.init).flatMap(SettingsWindowController.Tab.init) {
            showSettings(tab: tab)
        }
        #endif
    }

    /// Runs on the first run-loop turn after the window is ordered front (S22 target: < 300 ms warm).
    private static func logLaunchTime() {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return }
        let start = info.kp_proc.p_starttime
        let ms = (Date().timeIntervalSince1970 - (Double(start.tv_sec) + Double(start.tv_usec) / 1e6)) * 1000
        Logger(subsystem: "com.meetily.ai", category: "launch").notice("window visible \(Int(ms), privacy: .public) ms after process start")
    }

    @objc func showSettings(_ sender: Any?) { showSettings(tab: nil) }

    /// The main window, or onboarding while it is still open.
    @objc func showMainWindow(_ sender: Any?) {
        (onboarding ?? mainWindow)?.showWindow(nil)
        NSApp.activate()
    }

    func showSettings(tab: SettingsWindowController.Tab?) {
        guard let model else { return }
        if settingsWindow == nil { settingsWindow = SettingsWindowController(model: model) }
        settingsWindow?.show(tab)
    }

    /// Quit Meety (menu, status item, Dock, logout). AppKit refuses `terminate:` while a sheet is attached, so sheets
    /// end first; pending edits and a recording in progress are saved first (in `terminateLater` the main actor never
    /// ran the save). If the recording can't be saved, quitting stops so the error stays on screen.
    @objc func quit(_ sender: Any?) {
        guard !quitting else { return }
        quitting = true
        for window in NSApp.windows { if let sheet = window.attachedSheet { window.endSheet(sheet) } }
        Task {
            await mainWindow?.flushEdits()
            if let recorder = model?.recorder {
                let live = recorder.phase == .recording || recorder.phase == .paused
                if live, await recorder.stop() == nil {
                    quitting = false
                    model?.route = .home // the recording screen shows the failure
                    showMainWindow(nil)
                    return
                }
                while recorder.phase == .stopping { try? await Task.sleep(for: .milliseconds(100)) } // a stop already running
            }
            NSApp.terminate(sender)
        }
    }

    @objc private func handleQuitEvent(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) { quit(nil) }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showMainWindow(nil) }
        return true
    }
}
