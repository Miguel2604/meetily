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
    public static var parakeetModels: URL { models.appending(path: "parakeet", directoryHint: .isDirectory) }
    public static var summaryModels: URL { models.appending(path: "summary", directoryHint: .isDirectory) }
    /// Whisper ggml files sit directly in `models/`, as in the Tauri app.
    public static var whisperModels: URL { models }

    /// Port of `sanitize_filename`: path and shell-hostile characters and controls become `_`, then trim.
    public static func sanitizeFilename(_ name: String) -> String {
        String(name.map { c -> Character in
            if "/\\:*?\"<>|".contains(c) || c.unicodeScalars.allSatisfy({ CharacterSet.controlCharacters.contains($0) }) { return "_" }
            return c
        }).trimmingCharacters(in: .whitespaces)
    }

    /// Port of `create_meeting_folder` naming: `<sanitized name>_<YYYY-MM-DD_HH-MM in UTC>`.
    public static func meetingFolder(base: URL, name: String, date: Date = Date()) -> URL {
        let stamp = date.formatted(Date.VerbatimFormatStyle(
            format: "\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits)_\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased))-\(minute: .twoDigits)",
            timeZone: .gmt, calendar: Calendar(identifier: .gregorian)))
        return base.appending(path: "\(sanitizeFilename(name))_\(stamp)", directoryHint: .isDirectory)
    }
}
