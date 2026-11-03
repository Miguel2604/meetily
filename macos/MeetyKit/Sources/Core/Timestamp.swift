import Foundation

/// Timestamps as the Tauri app (chrono + sqlx) writes them: RFC 3339, microseconds, `+00:00`.
public enum Timestamp {
    private static let writer = formatter("yyyy-MM-dd'T'HH:mm:ss.SSSSSSxxx")
    private static let readers = [
        "yyyy-MM-dd'T'HH:mm:ss.SSSSSSSSSxxx", "yyyy-MM-dd'T'HH:mm:ss.SSSSSSxxx", "yyyy-MM-dd'T'HH:mm:ss.SSSxxx",
        "yyyy-MM-dd'T'HH:mm:ssxxx", "yyyy-MM-dd HH:mm:ss.SSSSSS", "yyyy-MM-dd HH:mm:ss",
    ].map(formatter)

    public static func now() -> String { string(from: Date()) }
    public static func string(from date: Date) -> String { writer.string(from: date) }

    public static func parse(_ text: String) -> Date? {
        for reader in readers { if let date = reader.date(from: text) { return date } }
        return nil
    }

    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = format
        return f
    }
}
