import Foundation
import Testing
@testable import Summary

// Ports of the processor.rs, templates and language_detection.rs unit tests.

@Suite struct ProcessorTests {
    @Test func `chunking keeps content after an early sentence boundary`() {
        let chunks = chunkText("Intro. LOST_MARKER trailing content ensures chunking", tokens: 10, overlap: 1)
        #expect(chunks.contains { $0.contains("LOST_MARKER") })
    }

    @Test func `chunking keeps Unicode boundaries`() {
        #expect(chunkText("é ab", tokens: 1, overlap: 0) == ["é ", "ab"])
    }

    @Test func `chunking progresses when the overlap matches the window`() {
        #expect(chunkText("abcd", tokens: 1, overlap: 1) == ["abc", "bcd"])
        #expect(chunkText("", tokens: 10, overlap: 1).isEmpty)
        #expect(chunkText("short", tokens: 10, overlap: 1) == ["short"])
    }

    @Test func `token estimate is 0.35 per character, rounded up`() {
        #expect(roughTokenCount("") == 0)
        #expect(roughTokenCount("abc") == 2)
        #expect(roughTokenCount(String(repeating: "é", count: 100)) == 35)
    }

    @Test func `the meeting name is the first H1`() {
        #expect(meetingName(fromMarkdown: "intro\n## Sub\n# Weekly Sync \nbody") == "Weekly Sync")
        #expect(meetingName(fromMarkdown: "## Only sub") == nil)
    }

    @Test func `every pass forces an English base and forbids reasoning`() {
        let chunk = chunkSummaryPrompt("会議の内容")
        #expect(chunk.contains(englishBaseInstruction) && chunk.contains("<transcript_chunk>"))
        #expect(chunk.contains("Do not include reasoning"))
        let combine = combineSummaryPrompt("chunk one\n---\nchunk two")
        #expect(combine.contains(englishBaseInstruction) && combine.contains("<summaries>"))
        let report = finalReportSystemPrompt(sections: "Fill the section", template: "# <Add Title here>")
        #expect(report.contains(englishBaseInstruction) && report.contains("SECTION-SPECIFIC INSTRUCTIONS"))
        #expect(report.contains("meta-commentary"))
        #expect(englishBaseInstruction.contains("non-English prose is invalid") && englishBaseInstruction.utf8.count <= 120)
    }

    @Test func `the final language action follows the target and the transcript language`() {
        #expect(finalLanguageAction(summaryLanguage: "en", detected: "en") == .returnEnglish)
        #expect(finalLanguageAction(summaryLanguage: "en", detected: "ja") == .normalizeEnglish)
        #expect(finalLanguageAction(summaryLanguage: "en", detected: nil) == .normalizeEnglish)
        #expect(finalLanguageAction(summaryLanguage: "fr", detected: "ja") == .translate("French"))
        #expect(finalLanguageAction(summaryLanguage: nil, detected: "en") == .returnEnglish)
    }

    @Test func `language names cover regional tags and reject unknown codes`() {
        #expect(languageName(code: "pt-BR") == "Portuguese")
        #expect(languageName(code: "en_GB") == "English")
        #expect(languageName(code: "zh-TW") == "Traditional Chinese")
        #expect(languageName(code: "zh-CN") == "Chinese")
        #expect(languageName(code: "tl") == nil)
    }

    @Test func `normalization falls back to the pass-1 markdown unless cancelled`() throws {
        let fallback = try englishAfterNormalization(original: "# Original", result: .success(Cleaned(markdown: "", reasoningStripped: true)))
        #expect(fallback.0 == Cleaned(markdown: "# Original", reasoningStripped: true))
        #expect(fallback.1)
        let failed = try englishAfterNormalization(original: "# Original", result: .failure(.message("boom")))
        #expect(failed.0 == Cleaned(markdown: "# Original", reasoningStripped: false) && failed.1)
        #expect(throws: LLMError.cancelled) {
            try englishAfterNormalization(original: "# Original", result: .failure(.cancelled))
        }
    }

    @Test(arguments: [
        (nil, nil, nil), ("", "fr", nil), ("   \n", "fr", nil), ("body", nil, nil), ("body", "en", nil), ("body", "en-GB", nil),
        ("body", "fr", "body"), ("body", "zz-unknown", nil), ("body", "FR", "body"), ("body", "EN", nil), ("body", "en_GB", nil),
    ] as [(String?, String?, String?)])
    func `a cached English summary is reused only for a translation target`(cached: String?, language: String?, expected: String?) {
        #expect(resolveCachedEnglish(cached, summaryLanguage: language) == expected)
    }

    @Test func `the cleaner removes closed reasoning envelopes everywhere`() {
        let cleaned = cleanMarkdown("Intro\n<think>private</think>\n# Meeting\nHello\n<thinking>also private</thinking>\nTail")
        #expect(cleaned.reasoningStripped)
        #expect(!cleaned.markdown.contains("<think"))
        #expect(cleaned.markdown.contains("Intro") && cleaned.markdown.contains("# Meeting") && cleaned.markdown.contains("Tail"))

        let fenced = cleanMarkdown("```\n<think>private</think>\nvisible\n```")
        #expect(fenced == Cleaned(markdown: "visible", reasoningStripped: true))

        let attributed = cleanMarkdown("Visible\n<thinking class=\"internal\">private</thinking>\nTail")
        #expect(attributed.reasoningStripped && !attributed.markdown.contains("private"))

        #expect(cleanMarkdown("<thinker>Visible</thinker>") == Cleaned(markdown: "<thinker>Visible</thinker>", reasoningStripped: false))
    }

    @Test(arguments: ["Visible\n<think>private", "Visible\n</thinking>", "Visible\n<think class=\"internal\">private"])
    func `the cleaner rejects unterminated reasoning markers`(raw: String) {
        #expect(throws: LLMError.message("Final summary contained an unterminated reasoning marker")) {
            try requireVisible("Final summary", cleanMarkdown(raw))
        }
    }

    @Test func `reasoning-only output and empty fences have no visible content`() {
        #expect(throws: LLMError.message("Final summary returned no visible summary content after reasoning removal")) {
            try requireVisible("Final summary", cleanMarkdown("<think>private</think>"))
        }
        for raw in ["```\n```", "```markdown\n```", "```\r\n```", "```markdown\r\n```"] {
            #expect(cleanMarkdown(raw).markdown == "")
            #expect(throws: LLMError.message("Translation returned no visible summary content after reasoning removal")) {
                try requireVisible("Translation", cleanMarkdown(raw))
            }
        }
    }

    @Test func `the cleaner strips an outer CRLF fence without touching the markdown inside`() {
        let markdown = "# Heading\r\n\r\n```rust\r\nlet x = 1;\r\n```"
        #expect(cleanMarkdown("```\r\n\(markdown)\r\n```") == Cleaned(markdown: markdown, reasoningStripped: false))
        #expect(cleanMarkdown(markdown).markdown == markdown)
    }
}

@Suite struct TemplateTests {
    @Test func `the six bundled templates load and validate`() throws {
        #expect(Templates.ids(customDirectory: nil) == ["daily_standup", "project_sync", "psychatric_session", "retrospective",
                                                         "sales_marketing_client_call", "standard_meeting"])
        let standup = try Templates.load("daily_standup", customDirectory: nil)
        #expect(standup.name == "Daily Standup")
        #expect(!standup.sections.isEmpty)
        #expect(throws: TemplateError.self) { try Templates.load("nope", customDirectory: nil) }
    }

    @Test func `a custom template overrides the bundled one`() throws {
        let dir = scratch()
        try #"{"name":"Mine","description":"d","sections":[{"title":"S","instruction":"i","format":"list"}]}"#
            .write(to: dir.appending(path: "daily_standup.json"), atomically: true, encoding: .utf8)
        try #"{"name":"Extra","description":"d","sections":[{"title":"S","instruction":"i","format":"list"}]}"#
            .write(to: dir.appending(path: "extra.json"), atomically: true, encoding: .utf8)
        #expect(try Templates.load("daily_standup", customDirectory: dir).name == "Mine")
        #expect(Templates.ids(customDirectory: dir).contains("extra"))
    }

    @Test func `validation rejects empty names, no sections and unknown formats`() {
        let section = Template.Section(title: "T", instruction: "i", format: "invalid")
        #expect(throws: TemplateError.self) { try Template(name: "", description: "d", sections: []).validate() }
        #expect(throws: TemplateError.self) { try Template(name: "n", description: "d", sections: []).validate() }
        #expect(throws: TemplateError.self) { try Template(name: "n", description: "d", sections: [section]).validate() }
        #expect(throws: TemplateError.self) { try Templates.parse(Data("{".utf8)) }
    }

    @Test func `templates render the markdown skeleton and section instructions`() {
        let template = Template(name: "n", description: "d", sections: [
            Template.Section(title: "Summary", instruction: "Sum it up", format: "paragraph"),
            Template.Section(title: "Actions", instruction: "List them", format: "list", itemFormat: "| Owner | Task |"),
        ])
        #expect(template.markdownStructure == "# <Add Title here>\n\n**Summary**\n\n**Actions**\n\n")
        #expect(template.sectionInstructions == """
        - **For the main title (`# [AI-Generated Title]`):** Analyze the entire transcript and create a concise, descriptive title for the meeting.
        - **For the 'Summary' section:** Sum it up.
        - **For the 'Actions' section:** List them.
          - Items in this section should follow the format: `| Owner | Task |`.

        """)
    }
}

@Suite struct LanguageDetectionTests {
    @Test func `detects English`() {
        let result = detectSummaryLanguage(["The team reviewed the roadmap, discussed release blockers, and agreed on the next engineering milestones."])
        #expect(result == LanguageDetection(language: "en", reason: .detected))
    }

    @Test func `detects Chinese`() {
        #expect(detectSummaryLanguage(["团队讨论了产品路线图、发布风险以及下一阶段的工程计划，并确认了后续负责人。"]).language == "zh")
    }

    @Test func `uses the weighted dominant language`() {
        let texts = [
            "团队讨论了产品路线图、发布风险以及下一阶段的工程计划，并确认了后续负责人。",
            "The team spent most of the meeting reviewing launch risks, customer feedback, engineering follow-ups, staffing constraints, and the next release timeline.",
            "The group also assigned owners for documentation, QA verification, support readiness, and deployment communications.",
        ]
        #expect(detectSummaryLanguage(texts).language == "en")
    }

    @Test func `reports a tie`() {
        #expect(dominantLanguage(["en": 40, "es": 40]) == LanguageDetection(language: nil, reason: .tie))
    }

    @Test func `short text has no language`() {
        #expect(detectSummaryLanguage(["ok", "12345", "..."]) == LanguageDetection(language: nil, reason: .empty))
    }
}
