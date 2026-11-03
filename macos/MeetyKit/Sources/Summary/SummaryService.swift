import Core
import Foundation

// Port of `summary/service.rs` and the read/save side of `summary/commands.rs`. The stored result JSON keeps the
// Tauri shape (D3): sorted keys, `markdown` without its title, and the `english_cache` the next run can reuse.

/// The inputs an English pass was generated from; the cache is reused only when all of them match.
struct CacheSource: Codable, Hashable, Sendable {
    var transcriptFingerprint: String
    var customPromptFingerprint: String
    var templateID: String
    var templateFingerprint: String
    var tokenThreshold: Int
    var provider: String
    var model: String
    var ollamaEndpoint: String?
    var customEndpoint: String?
    var maxTokens: Int?
    /// f32 in Rust, which writes 0.2 as 0.20000000298023224; Float compares equal either way.
    var temperature: Float?
    var topP: Float?

    init(transcript: String, customPrompt: String, templateID: String, templateFingerprint: String, tokenThreshold: Int,
         provider: String, model: String, ollamaEndpoint: String?, customEndpoint: String?, maxTokens: Int?, temperature: Float?, topP: Float?) {
        transcriptFingerprint = fnvFingerprint(transcript)
        customPromptFingerprint = fnvFingerprint(customPrompt)
        self.templateID = templateID
        self.templateFingerprint = templateFingerprint
        self.tokenThreshold = tokenThreshold
        self.provider = provider
        self.model = model
        self.ollamaEndpoint = ollamaEndpoint
        self.customEndpoint = customEndpoint
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.topP = topP
    }

    enum CodingKeys: String, CodingKey {
        case transcriptFingerprint = "transcript_fingerprint", customPromptFingerprint = "custom_prompt_fingerprint",
             templateID = "template_id", templateFingerprint = "template_fingerprint", tokenThreshold = "token_threshold",
             provider = "model_provider", model = "model_name", ollamaEndpoint = "ollama_endpoint",
             customEndpoint = "custom_openai_endpoint", maxTokens = "max_tokens", temperature, topP = "top_p"
    }

    /// Writes `null` for missing values, as serde does.
    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(transcriptFingerprint, forKey: .transcriptFingerprint)
        try c.encode(customPromptFingerprint, forKey: .customPromptFingerprint)
        try c.encode(templateID, forKey: .templateID)
        try c.encode(templateFingerprint, forKey: .templateFingerprint)
        try c.encode(tokenThreshold, forKey: .tokenThreshold)
        try c.encode(provider, forKey: .provider)
        try c.encode(model, forKey: .model)
        try c.encode(ollamaEndpoint, forKey: .ollamaEndpoint)
        try c.encode(customEndpoint, forKey: .customEndpoint)
        try c.encode(maxTokens, forKey: .maxTokens)
        try c.encode(temperature, forKey: .temperature)
        try c.encode(topP, forKey: .topP)
    }
}

struct EnglishCache: Codable {
    var markdown: String
    var source: CacheSource
    var outputLanguage: String?

    enum CodingKeys: String, CodingKey { case markdown, source, outputLanguage = "output_language" }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(markdown, forKey: .markdown)
        try c.encode(source, forKey: .source)
        try c.encode(outputLanguage, forKey: .outputLanguage)
    }
}

/// FNV-1a 64 over the UTF-8 bytes, then the byte length.
func fnvFingerprint(_ text: String) -> String {
    let hash = text.utf8.reduce(0xcbf2_9ce4_8422_2325 as UInt64) { ($0 ^ UInt64($1)) &* 0x100_0000_01b3 }
    return String(format: "%016llx:%d", hash, text.utf8.count)
}

func templateFingerprint(_ template: Template) -> String {
    fnvFingerprint("\(template.markdownStructure)\n---SECTION-INSTRUCTIONS---\n\(template.sectionInstructions)")
}

/// Drops everything up to the end of the line holding the first `#`; "" when there is none.
func stripLeadingTitle(_ markdown: String) -> String {
    guard let hash = markdown.firstIndex(of: "#") else { return "" }
    let body = markdown[hash...].firstIndex(where: \.isNewline) ?? markdown.endIndex
    return String(markdown[body...].drop(while: \.isWhitespace))
}

func stripTitleIfPresent(_ markdown: String) -> String {
    markdown.drop(while: \.isWhitespace).hasPrefix("# ") ? stripLeadingTitle(markdown) : markdown
}

func summaryResultJSON(final: String, english: String, source: CacheSource, outputLanguage: String?,
                       reasoningStripped: Bool, normalizationFallback: Bool) throws(LLMError) -> Data {
    let cleanedFinal = cleanMarkdown(final)
    try requireVisible("Final summary", cleanedFinal)
    let markdown = stripTitleIfPresent(cleanedFinal.markdown)
    guard !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw .message("Final summary contains no visible content after title removal")
    }
    let cleanedEnglish = cleanMarkdown(english)
    try requireVisible("English summary", cleanedEnglish)

    struct Result: Encodable {
        var english_cache: EnglishCache
        var markdown: String
        var normalization_fallback: Bool
        var reasoning_stripped: Bool
    }
    let result = Result(
        english_cache: EnglishCache(markdown: cleanedEnglish.markdown, source: source,
                                    outputLanguage: outputLanguage.flatMap { languageName(code: $0.trimmingCharacters(in: .whitespaces)) }),
        markdown: markdown, normalization_fallback: normalizationFallback,
        reasoning_stripped: reasoningStripped || cleanedFinal.reasoningStripped || cleanedEnglish.reasoningStripped)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    do { return try encoder.encode(result) } catch { throw .message("Failed to encode the summary: \(error)") }
}

/// The stored English pass, when it came from exactly these inputs and the user switched to another translation target.
/// Throws when the stored result is not JSON.
func cachedEnglish(_ raw: String, source: CacheSource, language: String?) throws -> String? {
    guard let requested = language.flatMap({ languageName(code: $0.trimmingCharacters(in: .whitespaces)) }), requested != "English" else { return nil }
    let object = try JSONSerialization.jsonObject(with: Data(raw.utf8))
    guard let value = (object as? [String: Any])?["english_cache"], JSONSerialization.isValidJSONObject(value),
          let cache = try? JSONDecoder().decode(EnglishCache.self, from: JSONSerialization.data(withJSONObject: value)),
          cache.source == source, cache.outputLanguage != requested,
          !cache.markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
    return cache.markdown
}

// MARK: Reading stored summaries (commands.rs)

/// Visible markdown, BlockNote blocks with text, or a legacy section with content, and no reasoning markers anywhere.
func summaryIsRenderable(_ summary: [String: Any]) -> Bool {
    func hasMarker(_ value: Any) -> Bool {
        switch value {
        case let items as [Any]: return items.contains(where: hasMarker)
        case let object as [String: Any]:
            return object.contains { key, value in
                switch key {
                case "markdown", "text", "content": (value as? String).map(containsReasoningMarker) ?? ((value as? [Any]).map(hasMarker) ?? false)
                case "summary_json", "children": hasMarker(value)
                default: false
                }
            }
        default: return false
        }
    }
    func blockText(_ value: Any) -> Bool {
        switch value {
        case let items as [Any]: return items.contains(where: blockText)
        case let object as [String: Any]:
            return (object["text"] as? String).map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? false
                || object["content"].map(blockText) ?? false || object["children"].map(blockText) ?? false
        default: return false
        }
    }
    if hasMarker(summary) { return false }
    if let markdown = summary["markdown"] { return (markdown as? String).map { !cleanMarkdown($0).markdown.isEmpty } ?? false }
    if let blocks = summary["summary_json"] { return blockText(blocks) }
    return summary.contains { key, value in
        key != "MeetingName" && key != "_section_order" && ((value as? [String: Any])?["blocks"] as? [[String: Any]] ?? []).contains {
            ($0["content"] as? String).map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? false
        }
    }
}

/// Cleans stored markdown on read and drops a `reasoning` field when the run flagged stripped reasoning.
func redactFlaggedReasoning(_ result: [String: Any]) -> [String: Any] {
    var result = result
    var stripped = result["reasoning_stripped"] as? Bool == true
    if stripped { result["reasoning"] = nil }
    if let markdown = result["markdown"] as? String {
        let cleaned = cleanMarkdown(markdown)
        result["markdown"] = cleaned.markdown
        stripped = stripped || cleaned.reasoningStripped
    }
    if var cache = result["english_cache"] as? [String: Any], let markdown = cache["markdown"] as? String {
        let cleaned = cleanMarkdown(markdown)
        cache["markdown"] = cleaned.markdown
        result["english_cache"] = cache
        stripped = stripped || cleaned.reasoningStripped
    }
    if stripped { result["reasoning_stripped"] = true }
    return result
}

/// What the summary pane shows (`api_get_summary`). Status is lowercase: idle, pending, completed, failed, cancelled, error.
public struct SummaryState: @unchecked Sendable { // `data` is an immutable JSON tree
    public let status: String
    public let meetingName: String?
    public let processID: String?
    public let end: String?
    public let data: [String: Any]?
    public let error: String?

    public var markdown: String? { data?["markdown"] as? String }
}

public struct SummaryRun: Sendable {
    /// The run's start time; pass it to `cancel` so a newer run is never cancelled by mistake.
    public let processID: String
    public let task: Task<Void, Never>
}

/// Starts, cancels and reads meeting summaries. Runs write their outcome to `summary_processes`, compare-and-set on
/// the start time, so a superseded run can never overwrite a newer one.
public actor SummaryService {
    let store: Store
    let client: LLMClient
    let builtIn: BuiltInModels
    let apiKey: @Sendable (String) -> String?
    let templatesDirectory: URL?
    private var running: [String: (processID: String, task: Task<Void, Never>)] = [:]
    private var lastStart = Date.distantPast

    public init(store: Store, client: LLMClient = LLMClient(), builtIn: BuiltInModels,
                apiKey: @escaping @Sendable (String) -> String? = { Keychain().get($0) },
                templatesDirectory: URL? = Templates.customDirectory) {
        self.store = store
        self.client = client
        self.builtIn = builtIn
        self.apiKey = apiKey
        self.templatesDirectory = templatesDirectory
    }

    /// Marks the meeting's summary pending (the previous result is kept as the backup) and generates in the background.
    public func start(meetingID: String, text: String, provider: String, model: String, customPrompt: String = "",
                      templateID: String = "daily_standup", summaryLanguage: String?) async throws -> SummaryRun {
        let language = summaryLanguage.map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 }
        // Strictly increasing at the stored millisecond precision, so two quick starts never share an id.
        lastStart = max(Date(), lastStart.addingTimeInterval(0.001))
        let processID = Timestamp.string(from: lastStart)
        try await store.createOrResetProcess(meetingID: meetingID, startedAt: processID)
        do {
            try await store.saveTranscriptChunk(meetingID: meetingID, text: text, model: provider, modelName: model, chunkSize: 40000, overlap: 1000)
        } catch {
            _ = try? await store.failProcess(meetingID: meetingID, startedAt: processID, error: "Failed to save transcript data: \(error)")
            throw error
        }
        if let previous = running[meetingID] {
            guard previous.processID < processID else { throw LLMError.message("A newer summary run already started") }
            previous.task.cancel()
        }
        let task = Task {
            await self.process(meetingID: meetingID, processID: processID, text: text, providerID: provider, model: model,
                               customPrompt: customPrompt, templateID: templateID, language: language)
        }
        running[meetingID] = (processID, task)
        return SummaryRun(processID: processID, task: task)
    }

    /// Starts a summary with the saved provider and model (auto summary after a recording stops).
    /// Nil when no model is saved or the meeting has no transcript.
    public func startWithSavedModel(meetingID: String, templateID: String, language: String?) async throws -> SummaryRun? {
        guard let config = try await store.modelConfig(), !config.model.isEmpty else { return nil }
        let transcripts = try await store.transcripts(meetingID: meetingID)
        guard !transcripts.isEmpty else { return nil }
        return try await start(meetingID: meetingID, text: SummaryText.input(transcripts).text, provider: config.provider,
                               model: config.model, templateID: templateID, summaryLanguage: language)
    }

    /// Cancels the run with this id; false when it is not the active run or it already finished.
    public func cancel(meetingID: String, processID: String) async throws -> Bool {
        guard let run = running[meetingID], run.processID == processID else { return false }
        run.task.cancel()
        return try await store.cancelProcess(meetingID: meetingID, startedAt: processID)
    }

    public func summary(meetingID: String) async throws -> SummaryState {
        let name = try await store.meeting(id: meetingID)?.title
        guard let process = try await store.summaryProcess(meetingID: meetingID) else {
            return SummaryState(status: "idle", meetingName: name, processID: nil, end: nil, data: nil, error: nil)
        }
        var status = process.status.lowercased(), error = process.error
        // Parsed whatever the status, so a summary restored after a cancel or failure still shows.
        var data = process.result.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }.map(redactFlaggedReasoning)
        if status == "completed", !(data.map(summaryIsRenderable) ?? false) {
            status = "error"
            error = "Stored summary data is missing or invalid. Generate the summary again."
            data = nil
        }
        return SummaryState(status: status, meetingName: name, processID: process.startTime, end: process.endTime, data: data, error: error)
    }

    /// Saves a summary the user edited (`{"markdown": ...}` or BlockNote `summary_json`).
    public func save(meetingID: String, summary: [String: Any]) async throws {
        guard summaryIsRenderable(summary) else {
            throw LLMError.message("Summary contains no visible content or model reasoning markers and was not saved.")
        }
        let json = try JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys, .withoutEscapingSlashes])
        guard try await store.updateSummaryResult(meetingID: meetingID, result: String(decoding: json, as: UTF8.self)) else {
            throw LLMError.message("Meeting not found or can't convert the json")
        }
    }

    // MARK: The run

    private func process(meetingID: String, processID: String, text: String, providerID: String, model: String,
                         customPrompt: String, templateID: String, language: String?) async {
        let clock = ContinuousClock.now
        defer { if running[meetingID]?.processID == processID { running[meetingID] = nil } }
        do throws(LLMError) {
            let (generated, source) = try await generate(meetingID: meetingID, text: text, providerID: providerID, model: model,
                                                         customPrompt: customPrompt, templateID: templateID, language: language)
            let json = try summaryResultJSON(final: generated.finalMarkdown, english: generated.englishMarkdown, source: source,
                                             outputLanguage: language, reasoningStripped: generated.reasoningStripped,
                                             normalizationFallback: generated.normalizationFallback)
            let elapsed = ContinuousClock.now - clock
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            guard (try? await store.completeProcess(meetingID: meetingID, startedAt: processID, result: String(decoding: json, as: UTF8.self),
                                                    chunkCount: generated.chunkCount, processingTime: seconds)) == true else {
                log.warning("Skipped a stale summary completion for \(meetingID, privacy: .public)")
                return
            }
            if let name = meetingName(fromMarkdown: generated.finalMarkdown), !name.isEmpty {
                _ = try? await store.renameMeeting(id: meetingID, title: name)
            }
        } catch {
            if error == .cancelled || Task.isCancelled {
                _ = try? await store.cancelProcess(meetingID: meetingID, startedAt: processID)
            } else {
                log.error("Summary failed for \(meetingID, privacy: .public): \(error.description, privacy: .public)")
                _ = try? await store.failProcess(meetingID: meetingID, startedAt: processID, error: error.description)
            }
        }
    }

    private func generate(meetingID: String, text: String, providerID: String, model: String, customPrompt: String,
                          templateID: String, language: String?) async throws(LLMError) -> (GeneratedSummary, CacheSource) {
        guard let provider = Provider(id: providerID) else { throw .message("Unsupported LLM provider: \(providerID)") }
        var key = ""
        if [.openai, .claude, .groq, .openrouter].contains(provider) {
            guard let stored = apiKey(provider.rawValue), !stored.isEmpty else { throw .message("API key not found for \(providerID)") }
            key = stored
        }
        let config = try? await store.modelConfig()
        let ollamaEndpoint = provider == .ollama ? config?.ollamaEndpoint.flatMap { $0.isEmpty ? nil : $0 } : nil
        var custom: (endpoint: String, maxTokens: Int?, temperature: Float?, topP: Float?)?
        if provider == .customOpenAI {
            guard let json = config?.customOpenAIConfig.flatMap({ try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }),
                  let endpoint = json["endpoint"] as? String else {
                throw .message("Custom OpenAI provider selected but no configuration found")
            }
            custom = (endpoint, json["maxTokens"] as? Int, (json["temperature"] as? Double).map(Float.init), (json["topP"] as? Double).map(Float.init))
            key = apiKey(Provider.customOpenAI.rawValue) ?? json["apiKey"] as? String ?? ""
        }

        // Local models get the transcript in chunks that fit their context, less 300 tokens for the prompt.
        let threshold = switch provider {
        case .ollama: await client.ollamaContextSize(model, endpoint: ollamaEndpoint) - 300
        case .builtin: (BuiltInModel.named(model)?.contextSize ?? 2048) - 300
        default: 100_000
        }
        let template: Template
        do { template = try Templates.load(templateID, customDirectory: templatesDirectory) } catch {
            throw .message("Failed to load template '\(templateID)': \(error)")
        }
        let source = CacheSource(transcript: text, customPrompt: customPrompt, templateID: templateID,
                                 templateFingerprint: templateFingerprint(template), tokenThreshold: threshold, provider: providerID,
                                 model: model, ollamaEndpoint: ollamaEndpoint, customEndpoint: custom?.endpoint,
                                 maxTokens: custom?.maxTokens, temperature: custom?.temperature, topP: custom?.topP)
        let previous = try? await store.summaryProcess(meetingID: meetingID)?.result
        let cached = previous.flatMap { raw in
            do { return try cachedEnglish(raw, source: source, language: language) } catch {
                log.warning("Stored summary for \(meetingID, privacy: .public) is not valid JSON; ignoring the cache")
                return nil
            }
        }
        let detected = await detectedLanguage(meetingID: meetingID) ?? detectSummaryLanguage([text]).language

        let (client, builtIn) = (client, builtIn)
        let generate: Generate = { (system: String, user: String) async throws(LLMError) -> Completion in
            guard provider == .builtin else {
                return try await client.complete(LLMRequest(
                    provider: provider, model: model, apiKey: key, system: system, user: user, ollamaEndpoint: ollamaEndpoint,
                    customEndpoint: custom?.endpoint, maxTokens: custom?.maxTokens, temperature: custom?.temperature.map(Double.init),
                    topP: custom?.topP.map(Double.init)))
            }
            do {
                return Completion(content: try await builtIn.generate(model: model, system: system, user: user), reasoningStripped: false)
            } catch is CancellationError {
                throw .cancelled
            } catch {
                throw .message("Generation failed: \(error.localizedDescription)")
            }
        }
        let generated = try await generateMeetingSummary(
            text: text, customPrompt: customPrompt, template: template, tokenThreshold: threshold,
            chunked: provider == .ollama || provider == .builtin, summaryLanguage: language, detectedLanguage: detected,
            cachedEnglish: cached, generate: generate)
        return (generated, source)
    }

    /// `detected_summary_language` from the meeting folder's metadata.json, as the Tauri app saved it.
    private func detectedLanguage(meetingID: String) async -> String? {
        guard let folder = try? await store.meeting(id: meetingID)?.folderPath, !folder.isEmpty,
              let data = try? Data(contentsOf: URL(fileURLWithPath: folder).appending(path: "metadata.json")),
              let code = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["detected_summary_language"] as? String,
              languageName(code: code.trimmingCharacters(in: .whitespaces)) != nil else { return nil }
        return code.trimmingCharacters(in: .whitespaces)
    }
}
