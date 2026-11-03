import AppKit

#if DEBUG
/// `MEETY_SNAPSHOT=/path.png` renders the main window's content to a PNG after launch and quits,
/// so UI changes can be checked without screen-recording permission.
enum DebugSnapshot {
    static func scheduleIfRequested(_ window: NSWindow) {
        guard let path = ProcessInfo.processInfo.environment["MEETY_SNAPSHOT"] else { return }
        let delay = Double(ProcessInfo.processInfo.environment["MEETY_SNAPSHOT_DELAY"] ?? "") ?? 1.5
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard let view = window.contentView?.superview, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            NSApp.terminate(nil)
        }
    }
}
#endif
