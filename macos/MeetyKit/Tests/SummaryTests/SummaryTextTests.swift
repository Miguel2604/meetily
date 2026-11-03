@testable import Core
import Foundation
import Testing
@testable import Summary

@Suite struct SummaryTextTests {
    func transcript(_ text: String, _ start: Double?, timestamp: String = "2026-11-04T09:00:00+00:00") -> Transcript {
        Transcript(id: UUID().uuidString, meetingID: "m", transcript: text, timestamp: timestamp, audioStartTime: start)
    }

    @Test func `the summary input is one timestamped line per segment`() {
        let input = SummaryText.input([transcript("Hello", 0), transcript("Budget", 75.9), transcript("Old", nil, timestamp: "09:00")])
        #expect(input.text == "[00:00] Hello\n[01:15] Budget\n09:00 Old")
        #expect(input.texts == ["Hello", "Budget", "Old"])
    }

    @Test func `markdown comes from markdown, BlockNote blocks or legacy sections`() {
        #expect(SummaryText.markdown(from: ["markdown": "## Points\nShip"]) == "## Points\nShip")
        let blocks: [[String: Any]] = [
            ["type": "heading", "props": ["level": 2], "content": [["type": "text", "text": "Decisions", "styles": [:]]]],
            ["type": "bulletListItem", "content": [["type": "text", "text": "Ship ", "styles": [:]], ["type": "text", "text": "Friday", "styles": ["bold": true]]],
             "children": [["type": "bulletListItem", "content": [["type": "text", "text": "after QA", "styles": [:]]]]]],
            ["type": "numberedListItem", "content": [["type": "text", "text": "Write notes", "styles": [:]]]],
            ["type": "paragraph", "content": [] as [Any]],
            ["type": "paragraph", "content": [["type": "text", "text": "Done.", "styles": [:]]]],
        ]
        #expect(SummaryText.markdown(from: ["summary_json": blocks]) == "## Decisions\n- Ship **Friday**\n  - after QA\n1. Write notes\n\nDone.")
        let legacy: [String: Any] = ["MeetingName": "Sync", "ActionItems": ["title": "Action Items", "blocks": [["content": "Email Ana"]]],
                                     "KeyPoints": ["title": "Key Points", "blocks": [["content": "Budget ok"], ["content": "Hire"]]]]
        #expect(SummaryText.markdown(from: legacy) == "## Action Items\n\n- Email Ana\n\n## Key Points\n\n- Budget ok\n- Hire")
        #expect(SummaryText.markdown(from: ["markdown": "  "]) == nil)
    }

    @Test func `copy formats match the web app`() {
        let date = Timestamp.parse("2026-11-04T09:00:00+00:00")!
        #expect(SummaryText.transcriptCopy(meetingID: "m1", title: "Sync", date: date, transcripts: [transcript("Hello", 3)], dateStyle: { _ in "11/4/2026" })
                == "# Transcript of the Meeting: m1 - Sync\n\n## Date: 11/4/2026\n\n[00:03] Hello  ")
        #expect(SummaryText.summaryCopy(meetingID: "m1", title: "Sync", date: date, copied: date, markdown: "## Points", dateStyle: { _ in "November 4, 2026" })
                == "# Meeting Summary: Sync\n\n**Meeting ID:** m1\n**Date:** November 4, 2026\n**Copied on:** November 4, 2026\n\n---\n\n## Points")
    }
}

@Suite struct MarkdownSpansTests {
    @Test func `finds headings, list items and bold runs by UTF-16 range`() {
        let text = "# Title\nIntro **bold** text\n- item\n  1. nested\n## Sub"
        let spans = MarkdownSpans.parse(text)
        let ns = text as NSString
        func strings(_ kind: (MarkdownSpans.Span) -> Bool) -> [String] { spans.filter(kind).map { ns.substring(with: $0.range) } }
        #expect(strings { if case .heading = $0.kind { true } else { false } } == ["# Title", "## Sub"])
        #expect(spans.compactMap { if case .heading(let level) = $0.kind { level } else { nil } } == [1, 2])
        #expect(strings { $0.kind == .listItem } == ["- item", "  1. nested"])
        #expect(strings { $0.kind == .bold } == ["**bold**"])
        #expect(strings { $0.kind == .marker } == ["#", "**", "**", "-", "1.", "##"])
    }
}
