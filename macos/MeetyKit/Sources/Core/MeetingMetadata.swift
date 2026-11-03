import Foundation

/// A meeting folder's `metadata.json`, shared with the Tauri app.
public enum MeetingMetadata {
    public static func read(in folder: URL) -> [String: Any]? {
        (try? Data(contentsOf: folder.appending(path: "metadata.json"))).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    /// Rewrites the file from its current contents (nil when there is none yet).
    public static func update(in folder: URL, _ change: ([String: Any]?) -> [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: change(read(in: folder)), options: [.prettyPrinted, .sortedKeys])
        try data.write(to: folder.appending(path: "metadata.json"), options: .atomic)
    }

    /// The per-meeting summary language override (`api_get_meeting_summary_language`).
    public static func summaryLanguage(in folder: URL) -> String? {
        (read(in: folder)?["summary_language"] as? String).map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 }
    }

    public static func setSummaryLanguage(_ code: String?, in folder: URL) throws {
        try update(in: folder) { existing in
            var metadata = existing ?? [:]
            metadata["summary_language"] = code
            return metadata
        }
    }
}
