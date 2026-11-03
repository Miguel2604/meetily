import Core
import Foundation
import Synchronization
import Testing
@testable import Summary

func source(_ text: String = "transcript body", prompt: String = "custom prompt", template: String = "standard_meeting",
            fingerprint: String = fnvFingerprint("standard template prompt"), threshold: Int = 3700, provider: String = "ollama",
            model: String = "gemma3:1b", ollama: String? = "http://localhost:11434", custom: String? = nil,
            maxTokens: Int? = nil, temperature: Float? = nil, topP: Float? = nil) -> CacheSource {
    CacheSource(transcript: text, customPrompt: prompt, templateID: template, templateFingerprint: fingerprint, tokenThreshold: threshold,
                provider: provider, model: model, ollamaEndpoint: ollama, customEndpoint: custom,
                maxTokens: maxTokens, temperature: temperature, topP: topP)
}

func resultJSON(_ final: String = "# Reunion\n## Points\nBonjour", english: String = "# Meeting\n## Points\nHello",
                language: String? = "fr", reasoning: Bool = false) throws -> String {
    String(decoding: try summaryResultJSON(final: final, english: english, source: source(), outputLanguage: language,
                                           reasoningStripped: reasoning, normalizationFallback: false), as: UTF8.self)
}

func object(_ json: String) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
}

// Ports of the service.rs unit tests.
@Suite struct ServiceHelperTests {
    @Test func `stripping the leading title`() {
        #expect(stripLeadingTitle("# Meeting Title\nThis is the body.\nMore content.") == "This is the body.\nMore content.")
        #expect(stripLeadingTitle("# Meeting Title") == "")
        #expect(stripLeadingTitle("No heading here.\nJust body.") == "")
        #expect(stripLeadingTitle("# Title\n## Subheading\nParagraph 1\n\nParagraph 2") == "## Subheading\nParagraph 1\n\nParagraph 2")
        #expect(stripLeadingTitle("# Title\n") == "")
        #expect(stripLeadingTitle("# Title\n   \n Body with leading spaces") == "Body with leading spaces")
    }

    @Test func `stripping a title only when the markdown starts with one`() {
        #expect(stripTitleIfPresent("## Action Items\nfoo") == "## Action Items\nfoo")
        #expect(stripTitleIfPresent("# Meeting Title\n## Action Items\nfoo") == "## Action Items\nfoo")
        #expect(stripTitleIfPresent("Just body text") == "Just body text")
        #expect(stripTitleIfPresent("#NoSpace\nbody") == "#NoSpace\nbody")
        let midDocument = "Some paragraph\n\n# H1 on line 3\n## Section\nbody"
        #expect(stripTitleIfPresent(midDocument) == midDocument)
        #expect(stripTitleIfPresent("  # Title\n## Section\nbody") == "## Section\nbody")
    }

    @Test func `the fingerprint is FNV-1a over UTF-8 plus the byte length`() {
        #expect(fnvFingerprint("") == "cbf29ce484222325:0")
        #expect(fnvFingerprint("a") == "af63dc4c8601ec8c:1")
        #expect(fnvFingerprint("é").hasSuffix(":2"))
    }

    @Test func `the template fingerprint changes with the rendered template`() {
        func template(_ title: String) -> Template {
            Template(name: "Test", description: "Test template", sections: [.init(title: title, instruction: "Summarize this section", format: "paragraph")])
        }
        #expect(templateFingerprint(template("Summary")) != templateFingerprint(template("Decisions")))
    }

    @Test func `a legacy english_markdown field is a cache miss`() throws {
        #expect(try cachedEnglish(##"{"markdown":"translated","english_markdown":"# Old English\nBody"}"##, source: source(), language: "de") == nil)
    }

    @Test func `a changed translation target reuses the English cache, the same one does not`() throws {
        let raw = try resultJSON()
        #expect(try cachedEnglish(raw, source: source(), language: "de") == "# Meeting\n## Points\nHello")
        #expect(try cachedEnglish(raw, source: source(), language: "fr") == nil)
        #expect(try cachedEnglish(raw, source: source(), language: "en") == nil)
    }

    @Test(arguments: [
        source("changed transcript"), source(prompt: "changed prompt"), source(template: "daily_standup"), source(provider: "openai"),
        source(model: "qwen2.5:3b"), source(ollama: "http://localhost:11500"),
        source(custom: "https://custom.example/v1", maxTokens: 2048, temperature: 0.2, topP: 0.9),
        source(fingerprint: fnvFingerprint("changed template prompt")), source(threshold: 8192),
    ])
    func `changed summary inputs reject the cache`(changed: CacheSource) throws {
        #expect(try cachedEnglish(resultJSON(), source: changed, language: "de") == nil)
    }

    @Test func `float sampling settings written by Rust as f64 still match`() throws {
        let rust = ##"{"english_cache":{"markdown":"# M\nB","output_language":"French","source":{"custom_openai_endpoint":"https://c/v1","custom_prompt_fingerprint":"\##(fnvFingerprint("custom prompt"))","max_tokens":2048,"model_name":"gemma3:1b","model_provider":"ollama","ollama_endpoint":"http://localhost:11434","temperature":0.20000000298023224,"template_fingerprint":"\##(fnvFingerprint("standard template prompt"))","template_id":"standard_meeting","token_threshold":3700,"top_p":0.8999999761581421,"transcript_fingerprint":"\##(fnvFingerprint("transcript body"))"}},"markdown":"B"}"##
        let expected = source(custom: "https://c/v1", maxTokens: 2048, temperature: 0.2, topP: 0.9)
        #expect(try cachedEnglish(rust, source: expected, language: "de") == "# M\nB")
    }

    @Test func `the result JSON strips the display title but keeps it in the cache`() throws {
        let result = try object(resultJSON("# Translated Title\n## Decisions\nDone", english: "# English Title\n## Decisions\nDone"))
        #expect(result["markdown"] as? String == "## Decisions\nDone")
        #expect((result["english_cache"] as? [String: Any])?["markdown"] as? String == "# English Title\n## Decisions\nDone")
        #expect((result["english_cache"] as? [String: Any])?["output_language"] as? String == "French")
        #expect(result["normalization_fallback"] as? Bool == false)
    }

    @Test func `the result JSON has the Tauri key order and nulls`() throws {
        let json = try resultJSON("# T\nBody", english: "# T\nBody", language: nil)
        #expect(json.hasPrefix(##"{"english_cache":{"markdown":"# T\nBody","output_language":null,"source":{"custom_openai_endpoint":null,"custom_prompt_fingerprint":"##))
        #expect(json.hasSuffix(#""markdown":"Body","normalization_fallback":false,"reasoning_stripped":false}"#))
        #expect(json.contains(#""ollama_endpoint":"http://localhost:11434""#)) // slashes unescaped, like serde
    }

    @Test func `a title-only summary is rejected and reasoning is never persisted`() throws {
        #expect(throws: LLMError.message("Final summary contains no visible content after title removal")) {
            try summaryResultJSON(final: "# Title", english: "# Title", source: source(), outputLanguage: nil, reasoningStripped: false, normalizationFallback: false)
        }
        let result = try object(resultJSON("# Title\nVisible", english: "# Title\nVisible", language: nil, reasoning: true))
        #expect(result["reasoning_stripped"] as? Bool == true)
        #expect(result["reasoning"] == nil)
    }

    @Test func `malformed stored JSON is an error`() {
        #expect(throws: (any Error).self) { try cachedEnglish("{ not valid json", source: source(), language: "de") }
    }

    // Ports of commands.rs read-side checks.

    @Test func `renderable summaries need visible markdown and no reasoning markers`() throws {
        #expect(!summaryIsRenderable(try object(#"{"markdown":"   "}"#)))
        #expect(!summaryIsRenderable(try object(#"{"markdown":"```\r\n```"}"#)))
        #expect(!summaryIsRenderable(try object(#"{"markdown":"Visible <think>x"}"#)))
        #expect(summaryIsRenderable(try object(#"{"markdown":"Visible"}"#)))
        #expect(summaryIsRenderable(try object(#"{"summary_json":[{"content":[{"text":"Hi"}]}]}"#)))
        #expect(summaryIsRenderable(try object(#"{"MeetingName":"x","Summary":{"blocks":[{"content":"Point"}]}}"#)))
        #expect(!summaryIsRenderable(try object(#"{"MeetingName":"x","Summary":{"blocks":[{"content":" "}]}}"#)))
    }

    @Test func `flagged reasoning is redacted on read`() throws {
        let redacted = redactFlaggedReasoning(try object(#"{"reasoning_stripped":true,"reasoning":"private","markdown":"visible"}"#))
        #expect(redacted["reasoning"] == nil && redacted["markdown"] as? String == "visible")
        let kept = redactFlaggedReasoning(try object(#"{"reasoning":"custom","markdown":"visible"}"#))
        #expect(kept["reasoning"] as? String == "custom")
        let cleaned = redactFlaggedReasoning(try object(#"{"markdown":"Visible\n<think>private</think>\nTail"}"#))
        #expect(cleaned["markdown"] as? String == "Visible\n\nTail")
        #expect(cleaned["reasoning_stripped"] as? Bool == true)
    }
}

/// A fake provider: answers by pass, recording every system prompt it saw.
func fakeLLM(_ answer: @escaping @Sendable (_ system: String, _ user: String) -> Reply = { system, _ in
    let content = system.contains("translator") ? "# Réunion\\n## Points\\nBonjour" : "# Weekly Sync\\n## Points\\nShip Friday"
    return Reply(200, #"{"choices":[{"message":{"content":"\#(content)"}}]}"#)
}) -> Stub {
    Stub { seen in
        let messages = seen.json["messages"] as? [[String: String]] ?? []
        return answer(messages.first?["content"] ?? "", messages.last?["content"] ?? "")
    }
}

func systems(_ stub: Stub) -> [String] {
    stub.requests.map { ($0.json["messages"] as? [[String: String]])?.first?["content"] ?? "" }
}

@Suite struct SummaryServiceTests {
    let store: Store
    let meetingID: String

    init() async throws {
        store = try Store(path: scratch().appending(path: "meeting_minutes.sqlite").path)
        meetingID = try await store.saveMeeting(title: "Untitled", segments: [], folderPath: nil)
    }

    func service(_ stub: Stub, keys: [String: String] = ["openai": "sk"], builtIn: BuiltInModels? = nil) -> SummaryService {
        SummaryService(store: store, client: LLMClient(session: stub.session), builtIn: builtIn ?? BuiltInModels(directory: scratch()),
                       apiKey: { keys[$0] }, templatesDirectory: nil)
    }

    let english = "The team reviewed the roadmap, discussed release blockers, and agreed to ship the beta on Friday."

    @Test func `a summary completes, stores Tauri-shaped JSON and renames the meeting`() async throws {
        let stub = fakeLLM()
        let run = try await service(stub).start(meetingID: meetingID, text: english, provider: "openai", model: "gpt-6-astra",
                                                templateID: "standard_meeting", summaryLanguage: nil)
        await run.task.value
        let process = try #require(try await store.summaryProcess(meetingID: meetingID))
        #expect(process.status == "completed")
        #expect(process.startTime == run.processID)
        let result = try object(try #require(process.result))
        #expect(result["markdown"] as? String == "## Points\nShip Friday")
        #expect(try await store.meeting(id: meetingID)?.title == "Weekly Sync")
        #expect(systems(stub).count == 1) // detected English: no normalization pass
        #expect(systems(stub).first?.contains("SECTION-SPECIFIC INSTRUCTIONS") == true)
        #expect(stub.requests.first?.headers["Authorization"] == "Bearer sk")
        let state = try await service(stub).summary(meetingID: meetingID)
        #expect(state.status == "completed" && state.meetingName == "Weekly Sync")
        #expect(state.data?["markdown"] as? String == "## Points\nShip Friday")
    }

    @Test func `English transcripts skip the normalization pass`() async throws {
        let stub = fakeLLM()
        let run = try await service(stub).start(meetingID: meetingID, text: english, provider: "openai", model: "m", summaryLanguage: "en")
        await run.task.value
        #expect(systems(stub).count == 1)
    }

    @Test func `a missing API key fails the run`() async throws {
        let run = try await service(fakeLLM(), keys: [:]).start(meetingID: meetingID, text: english, provider: "openai", model: "m", summaryLanguage: nil)
        await run.task.value
        let process = try #require(try await store.summaryProcess(meetingID: meetingID))
        #expect(process.status == "failed")
        #expect(process.error == "API key not found for openai")
        let state = try await service(fakeLLM()).summary(meetingID: meetingID)
        #expect(state.status == "failed")
    }

    @Test func `cancelling restores the previous summary from the backup`() async throws {
        let first = fakeLLM()
        await (try await service(first).start(meetingID: meetingID, text: english, provider: "openai", model: "m", summaryLanguage: "en")).task.value
        let previous = try await store.summaryProcess(meetingID: meetingID)?.result

        let slow = fakeLLM { _, _ in Reply(200, completionJSON, delay: .seconds(30)) }
        let summaries = service(slow)
        let run = try await summaries.start(meetingID: meetingID, text: english, provider: "openai", model: "m", summaryLanguage: "en")
        while slow.requests.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(try await !summaries.cancel(meetingID: meetingID, processID: "2000-01-01T00:00:00.000000+00:00")) // stale id
        #expect(try await summaries.cancel(meetingID: meetingID, processID: run.processID))
        await run.task.value
        let process = try #require(try await store.summaryProcess(meetingID: meetingID))
        #expect(process.status == "cancelled")
        #expect(process.result == previous)
        #expect(try await !summaries.cancel(meetingID: meetingID, processID: run.processID)) // already done
    }

    @Test func `a new start supersedes the running one`() async throws {
        let slow = fakeLLM { _, _ in Reply(200, completionJSON, delay: .seconds(30)) }
        let summaries = service(slow)
        let first = try await summaries.start(meetingID: meetingID, text: english, provider: "openai", model: "m", summaryLanguage: "en")
        let second = try await summaries.start(meetingID: meetingID, text: english, provider: "openai", model: "m", summaryLanguage: "en")
        #expect(second.processID > first.processID)
        await first.task.value // cancelled by the second start; its stale write is skipped
        #expect(try await store.summaryProcess(meetingID: meetingID)?.status == "PENDING")
        #expect(try await summaries.cancel(meetingID: meetingID, processID: second.processID))
        await second.task.value
    }

    @Test func `a translation target translates, and switching targets reuses the English pass`() async throws {
        let stub = fakeLLM()
        let summaries = service(stub)
        await (try await summaries.start(meetingID: meetingID, text: english, provider: "openai", model: "m", summaryLanguage: "fr")).task.value
        #expect(systems(stub).count == 2)
        #expect(systems(stub).last?.contains("into French") == true)
        let result = try object(try #require(try await store.summaryProcess(meetingID: meetingID)?.result))
        #expect(result["markdown"] as? String == "## Points\nBonjour")
        #expect(try await store.meeting(id: meetingID)?.title == "Réunion")

        await (try await summaries.start(meetingID: meetingID, text: english, provider: "openai", model: "m", summaryLanguage: "de")).task.value
        #expect(systems(stub).count == 3) // only the German translation, no new English pass
        #expect(systems(stub).last?.contains("into German") == true)
    }

    @Test func `Ollama transcripts over the context are chunked, combined, then reported`() async throws {
        let stub = Stub { seen in
            if seen.url.path.hasSuffix("/api/show") { return Reply(200, #"{"model_info":{"llama.context_length":1400},"details":{"family":"llama"}}"#) }
            return Reply(200, ##"{"choices":[{"message":{"content":"# Sync\n## Notes\nPart"}}]}"##)
        }
        let long = Array(repeating: english, count: 80).joined(separator: " ") // ~2800 tokens against an 1100-token threshold
        await (try await service(stub).start(meetingID: meetingID, text: long, provider: "ollama", model: "llama3", summaryLanguage: "en")).task.value
        let prompts = systems(stub).filter { !$0.isEmpty }
        #expect(prompts.filter { $0 == "You are an expert meeting summarizer." }.count >= 3)
        #expect(prompts.contains("You are an expert at synthesizing meeting summaries."))
        #expect(prompts.last?.contains("SECTION-SPECIFIC INSTRUCTIONS") == true)
        let process = try #require(try await store.summaryProcess(meetingID: meetingID))
        #expect(process.status == "completed")
        #expect(process.chunkCount ?? 0 >= 3)
    }

    @Test func `built-in AI generates through the local model`() async throws {
        let dir = scratch()
        try (Data("GGUF".utf8) + Data(count: 1_048_572)).write(to: dir.appending(path: tinyLlama.file))
        final class Canned: LlamaRunner {
            func generate(prompt: String, maxTokens: Int, sampling: Sampling) async throws -> String { "# Local\n## Notes\nDone" }
        }
        let builtIn = BuiltInModels(directory: dir, catalog: [tinyLlama], load: { _, _ in Canned() })
        await (try await service(fakeLLM(), builtIn: builtIn).start(meetingID: meetingID, text: english, provider: "builtin-ai",
                                                                    model: "tiny:1b", summaryLanguage: "en")).task.value
        let process = try #require(try await store.summaryProcess(meetingID: meetingID))
        #expect(process.status == "completed")
        #expect(try object(try #require(process.result))["markdown"] as? String == "## Notes\nDone")
    }

    @Test func `the summary state is idle without a run and an error for unrenderable data`() async throws {
        let summaries = service(fakeLLM())
        #expect(try await summaries.summary(meetingID: meetingID).status == "idle")
        let start = Timestamp.now()
        try await store.createOrResetProcess(meetingID: meetingID, startedAt: start)
        _ = try await store.completeProcess(meetingID: meetingID, startedAt: start, result: #"{"markdown":"  "}"#, chunkCount: 1, processingTime: 1)
        let state = try await summaries.summary(meetingID: meetingID)
        #expect(state.status == "error")
        #expect(state.data == nil)
        #expect(state.error == "Stored summary data is missing or invalid. Generate the summary again.")
    }

    @Test func `saving an edited summary refuses invisible content`() async throws {
        let summaries = service(fakeLLM())
        await (try await summaries.start(meetingID: meetingID, text: english, provider: "openai", model: "m", summaryLanguage: "en")).task.value
        await #expect(throws: LLMError.self) { try await summaries.save(meetingID: meetingID, summary: ["markdown": "<think>x"]) }
        try await summaries.save(meetingID: meetingID, summary: ["markdown": "## Edited"])
        #expect(try await summaries.summary(meetingID: meetingID).data?["markdown"] as? String == "## Edited")
    }
}
