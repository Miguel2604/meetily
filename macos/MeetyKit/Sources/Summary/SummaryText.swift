import Core
import Foundation

/// Text the meeting screen builds from transcripts and stored summaries (useSummaryGeneration.ts, useCopyOperations.ts).
public enum SummaryText {
    /// `[mm:ss] text` per segment, joined by newlines: what the summary pipeline reads. `texts` feed language detection.
    public static func input(_ transcripts: [Transcript]) -> (text: String, texts: [String]) {
        (transcripts.map { "\(stamp($0)) \($0.transcript)" }.joined(separator: "\n"), transcripts.map(\.transcript))
    }

    /// The editable markdown of a stored summary: `markdown`, else BlockNote `summary_json`, else the legacy
    /// `{Section: {title, blocks: [{content}]}}` shape. Nil when there is no visible text.
    public static func markdown(from data: [String: Any]) -> String? {
        let text: String
        if let markdown = data["markdown"] as? String {
            text = markdown
        } else if let blocks = data["summary_json"] as? [[String: Any]] {
            text = lines(blocks, depth: 0).joined(separator: "\n")
        } else {
            // shortcut: legacy sections come back in key order, not the order the model wrote them; they predate the markdown format.
            text = data.keys.sorted().compactMap { key -> String? in
                guard let section = data[key] as? [String: Any], let title = section["title"] as? String,
                      let blocks = section["blocks"] as? [[String: Any]] else { return nil }
                return "## \(title)\n\n" + blocks.map { "- \($0["content"] as? String ?? "")" }.joined(separator: "\n")
            }.joined(separator: "\n\n")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }

    public static func transcriptCopy(meetingID: String, title: String, date: Date, transcripts: [Transcript],
                                      dateStyle: (Date) -> String = { $0.formatted(date: .numeric, time: .omitted) }) -> String {
        "# Transcript of the Meeting: \(meetingID) - \(title)\n\n## Date: \(dateStyle(date))\n\n"
            + transcripts.map { "\(stamp($0)) \($0.transcript)  " }.joined(separator: "\n")
    }

    public static func summaryCopy(meetingID: String, title: String, date: Date, copied: Date = Date(), markdown: String,
                                   dateStyle: (Date) -> String = { $0.formatted(date: .long, time: .shortened) }) -> String {
        "# Meeting Summary: \(title)\n\n**Meeting ID:** \(meetingID)\n**Date:** \(dateStyle(date))\n**Copied on:** \(dateStyle(copied))\n\n---\n\n" + markdown
    }

    private static func stamp(_ t: Transcript) -> String {
        guard let start = t.audioStartTime else { return t.timestamp }
        let s = Int(start)
        return String(format: "[%02d:%02d]", s / 60, s % 60)
    }

    private static func lines(_ blocks: [[String: Any]], depth: Int) -> [String] {
        blocks.flatMap { block -> [String] in
            let text = (block["content"] as? [[String: Any]] ?? []).map { run in
                let value = run["text"] as? String ?? (run["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined() ?? ""
                let styles = run["styles"] as? [String: Any] ?? [:]
                if styles["bold"] as? Bool == true { return "**\(value)**" }
                if styles["italic"] as? Bool == true { return "*\(value)*" }
                return value
            }.joined()
            let indent = String(repeating: "  ", count: depth)
            let line = switch block["type"] as? String {
            case "heading": String(repeating: "#", count: (block["props"] as? [String: Any])?["level"] as? Int ?? 1) + " " + text
            case "bulletListItem": "- " + text
            case "numberedListItem": "1. " + text
            case "checkListItem": "- [\((block["props"] as? [String: Any])?["checked"] as? Bool == true ? "x" : " ")] " + text
            default: text
            }
            return [indent + line] + lines(block["children"] as? [[String: Any]] ?? [], depth: depth + 1)
        }
    }
}

/// Where the summary editor styles markdown: headings, list items, bold runs and their syntax markers.
/// Ranges are UTF-16 (NSRange), ready for NSTextStorage.
public enum MarkdownSpans {
    public struct Span: Equatable, Sendable {
        public enum Kind: Equatable, Sendable { case heading(Int), listItem, bold, marker }
        public var kind: Kind
        public var range: NSRange
    }

    nonisolated(unsafe) private static let heading = try! NSRegularExpression(pattern: "^(#{1,6})\\s.*$")
    nonisolated(unsafe) private static let item = try! NSRegularExpression(pattern: "^\\s*([-*+]|\\d+[.)])\\s.*$")
    nonisolated(unsafe) private static let bold = try! NSRegularExpression(pattern: "\\*\\*(?=\\S)(.+?)(?<=\\S)\\*\\*")

    public static func parse(_ text: String) -> [Span] {
        let ns = text as NSString
        var spans: [Span] = []
        var location = 0
        while location < ns.length {
            let line = ns.lineRange(for: NSRange(location: location, length: 0))
            var content = line
            if content.length > 0, ns.character(at: NSMaxRange(content) - 1) == 10 { content.length -= 1 }
            if let m = heading.firstMatch(in: text, range: content) {
                spans.append(Span(kind: .heading(m.range(at: 1).length), range: m.range))
                spans.append(Span(kind: .marker, range: m.range(at: 1)))
            } else if let m = item.firstMatch(in: text, range: content) {
                spans.append(Span(kind: .listItem, range: m.range))
                spans.append(Span(kind: .marker, range: m.range(at: 1)))
            }
            for m in bold.matches(in: text, range: content) {
                spans.append(Span(kind: .bold, range: m.range))
                spans.append(Span(kind: .marker, range: NSRange(location: m.range.location, length: 2)))
                spans.append(Span(kind: .marker, range: NSRange(location: NSMaxRange(m.range) - 2, length: 2)))
            }
            location = NSMaxRange(line)
        }
        return spans
    }
}
