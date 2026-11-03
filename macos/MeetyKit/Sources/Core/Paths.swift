import Foundation

/// File locations shared with the Tauri app (D2): same bundle id, same data directory.
public enum Paths {
    public static let bundleIdentifier = "com.meetily.ai"

    /// `MEETY_DATA_DIR` points the app at a copy of the data (tests, unattended runs).
    public static var appSupport: URL {
        if let override = ProcessInfo.processInfo.environment["MEETY_DATA_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return URL.applicationSupportDirectory.appending(path: bundleIdentifier, directoryHint: .isDirectory)
    }

    public static var database: URL { appSupport.appending(path: "meeting_minutes.sqlite") }
    public static var models: URL { appSupport.appending(path: "models", directoryHint: .isDirectory) }
}
