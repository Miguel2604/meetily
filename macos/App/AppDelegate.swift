import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.make()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "Meety"
        window.contentView = EmptyStateView(symbol: "waveform", title: "Welcome to Meety", message: "Record a meeting to see its live transcript here.")
        window.minSize = NSSize(width: 760, height: 480)
        window.setFrameAutosaveName("MainWindow")
        if !window.setFrameUsingName("MainWindow") { window.center() }
        window.makeKeyAndOrderFront(nil)
        self.window = window
        #if DEBUG
        DebugSnapshot.scheduleIfRequested(window)
        #endif
        NSApp.activate()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { window?.makeKeyAndOrderFront(nil) }
        return true
    }
}
