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

/// Markdown parsed into the blocks the read view renders (headings, paragraphs, list items, GFM tables, rules).
/// Inline text keeps Foundation's `inlinePresentationIntent` (bold, italic, code) and `link`.
public enum MarkdownBlocks {
    public enum Block: Equatable, Sendable {
        case heading(Int, AttributedString)
        case paragraph(AttributedString, quote: Bool)
        case listItem(depth: Int, marker: String, AttributedString)
        /// Rows of cells; the first row is the header.
        case table([[AttributedString]])
        case rule
    }

    public static func parse(_ markdown: String) -> [Block] {
        let options = AttributedString.MarkdownParsingOptions(allowsExtendedAttributes: true, interpretedSyntax: .full,
                                                              failurePolicy: .returnPartiallyParsedIfPossible)
        guard let doc = try? AttributedString(markdown: markdown, options: options) else { return [.paragraph(AttributedString(markdown), quote: false)] }
        var blocks: [Block] = []
        var lastID: Int?
        for run in doc.runs {
            var text = AttributedString(doc[run.range])
            text.presentationIntent = nil
            let parts = run.presentationIntent?.components ?? []
            if let table = parts.first(where: { if case .table = $0.kind { true } else { false } }) {
                var row = 0, column = 0
                for part in parts {
                    if case .tableRow(let index) = part.kind { row = index }
                    if case .tableCell(let index) = part.kind { column = index }
                }
                var rows: [[AttributedString]] = []
                if lastID == table.identity, case .table(let existing) = blocks.last { rows = existing; blocks.removeLast() }
                while rows.count <= row { rows.append([]) }
                while rows[row].count <= column { rows[row].append(AttributedString()) }
                rows[row][column] += text
                blocks.append(.table(rows))
                lastID = table.identity
                continue
            }
            guard let block = parts.first else { continue }
            if lastID == block.identity, let last = blocks.popLast() {
                switch last {
                case .heading(let level, let old): blocks.append(.heading(level, old + text))
                case .paragraph(let old, let quote): blocks.append(.paragraph(old + text, quote: quote))
                case .listItem(let depth, let marker, let old): blocks.append(.listItem(depth: depth, marker: marker, old + text))
                default: blocks.append(last)
                }
                continue
            }
            lastID = block.identity
            if case .header(let level) = block.kind {
                blocks.append(.heading(level, text))
            } else if case .thematicBreak = block.kind {
                blocks.append(.rule)
            } else if let item = parts.firstIndex(where: { if case .listItem = $0.kind { true } else { false } }) {
                // shortcut: a list item's second paragraph gets its own marker; LLM summaries don't write those.
                let depth = parts.count { if case .listItem = $0.kind { true } else { false } }
                guard case .listItem(let ordinal) = parts[item].kind else { continue }
                let ordered = parts.indices.contains(item + 1) && parts[item + 1].kind == .orderedList
                blocks.append(.listItem(depth: depth, marker: ordered ? "\(ordinal)." : "•", text))
            } else {
                blocks.append(.paragraph(text, quote: parts.contains { $0.kind == .blockQuote }))
            }
        }
        return blocks
    }
}
