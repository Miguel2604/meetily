import AppKit
import Core

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel?
    private var mainWindow: MainWindowController?

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
        let model = AppModel(store: store, settings: Settings())
        let main = MainWindowController(model: model)
        main.showWindow(nil)
        self.model = model
        mainWindow = main
        Task { await model.reloadMeetings() }
        NSApp.activate()
        #if DEBUG
        if let window = main.window { DebugSnapshot.scheduleIfRequested(window) }
        #endif
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { mainWindow?.showWindow(nil) }
        return true
    }
}
