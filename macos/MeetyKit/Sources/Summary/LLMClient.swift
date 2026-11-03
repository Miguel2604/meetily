import Foundation
import os

let log = Logger(subsystem: "com.meetily.ai", category: "summary")

/// Summary providers, with the ids stored in the `settings` table.
public enum Provider: String, Sendable, CaseIterable {
    case openai, claude, groq, ollama, openrouter
    case builtin = "builtin-ai"
    case customOpenAI = "custom-openai"
    /// ChatGPT subscription through the Codex CLI (`codex login`), no API key.
    case chatgpt

    public init?(id: String) {
        switch id.lowercased() {
        case "local-llama", "localllama": self = .builtin
        case let id: self.init(rawValue: id)
        }
    }
}

public enum LLMError: Error, Equatable, CustomStringConvertible, LocalizedError {
    case cancelled
    case message(String)

    public var description: String {
        switch self {
        case .cancelled: "Summary generation was cancelled"
        case .message(let message): message
        }
    }

    public var errorDescription: String? { description }
}

/// The visible answer, and whether private reasoning was dropped from it.
public struct Completion: Sendable, Equatable {
    public var content: String
    public var reasoningStripped: Bool
}

public struct LLMRequest: Sendable {
    public var provider: Provider
    public var model: String
    public var apiKey: String
    public var system: String
    public var user: String
    public var ollamaEndpoint: String?
    public var customEndpoint: String?
    /// Sampling settings, sent only to custom OpenAI endpoints.
    public var maxTokens: Int?
    public var temperature: Double?
    public var topP: Double?

    public init(provider: Provider, model: String, apiKey: String = "", system: String, user: String,
                ollamaEndpoint: String? = nil, customEndpoint: String? = nil,
                maxTokens: Int? = nil, temperature: Double? = nil, topP: Double? = nil) {
        self.provider = provider
        self.model = model
        self.apiKey = apiKey
        self.system = system
        self.user = user
        self.ollamaEndpoint = ollamaEndpoint
        self.customEndpoint = customEndpoint
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.topP = topP
    }
}

/// Port of `llm_client.rs`: one OpenAI-compatible client, the Anthropic Messages API, and ChatGPT via the
/// Codex CLI. Cancelling the calling task cancels the request. Built-in AI is routed by the summary service.
public struct LLMClient: Sendable {
    static let timeout: TimeInterval = 300
    public static let defaultOllama = "http://localhost:11434"

    let session: URLSession

    public init(session: URLSession = .shared) { self.session = session }

    public func complete(_ request: LLMRequest) async throws(LLMError) -> Completion {
        guard !Task.isCancelled else { throw .cancelled }
        switch request.provider {
        case .builtin:
            throw .message("Built-in AI runs through BuiltInAI, not LLMClient")
        case .chatgpt:
            guard let codex = Self.findCodex() else {
                throw .message("Codex CLI not found. Install it and run `codex login` to use your ChatGPT subscription.")
            }
            return try await Self.codex(codex, model: request.model, system: request.system, user: request.user)
        case .claude:
            var http = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!, timeoutInterval: Self.timeout)
            http.setValue(request.apiKey, forHTTPHeaderField: "x-api-key")
            http.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            // Shared budget: on models with thinking on by default this covers thinking tokens as well as the answer.
            let body: [String: Any] = ["model": request.model, "max_tokens": 8192, "system": request.system,
                                       "messages": [["role": "user", "content": request.user]]]
            let (data, _) = try await post(&http, try json(body))
            return try Self.parseClaude(data)
        case .openai, .groq, .openrouter, .ollama, .customOpenAI:
            let url: String = switch request.provider {
            case .openai: "https://api.openai.com/v1/chat/completions"
            case .groq: "https://api.groq.com/openai/v1/chat/completions"
            case .openrouter: "https://openrouter.ai/api/v1/chat/completions"
            case .ollama: "\(request.ollamaEndpoint ?? Self.defaultOllama)/v1/chat/completions"
            default: "\(request.customEndpoint.map(trimSlash) ?? "")/chat/completions"
            }
            if request.provider == .customOpenAI, request.customEndpoint == nil { throw .message("Custom OpenAI endpoint not configured") }
            guard let target = URL(string: url) else { throw .message("Invalid endpoint: \(url)") }
            var http = URLRequest(url: target, timeoutInterval: Self.timeout)
            http.setValue("Bearer \(request.apiKey)", forHTTPHeaderField: "Authorization")
            var (data, status) = try await post(&http, try Self.chatBody(request), allowFailure: true)
            if !(200..<300).contains(status) {
                let text = String(decoding: data, as: UTF8.self)
                guard request.provider == .ollama, ollamaRejectsReasoningEffort(status: status, body: text) else {
                    throw .message("LLM API request failed with status \(status): \(text)")
                }
                log.warning("Ollama rejected reasoning_effort; retrying once without it")
                (data, _) = try await post(&http, try Self.chatBody(request, reasoningEffort: false))
            }
            return try Self.parseChat(data)
        }
    }

    // MARK: Bodies and responses

    static func chatBody(_ request: LLMRequest, reasoningEffort: Bool = true) throws(LLMError) -> Data {
        var body: [String: Any] = ["model": request.model, "messages": [
            ["role": "system", "content": request.system], ["role": "user", "content": request.user],
        ]]
        if request.provider == .customOpenAI {
            body["max_tokens"] = request.maxTokens
            body["temperature"] = request.temperature
            body["top_p"] = request.topP
        }
        if request.provider == .ollama, reasoningEffort { body["reasoning_effort"] = "none" }
        return try json(body)
    }

    static func parseChat(_ data: Data) throws(LLMError) -> Completion {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw .message("Failed to parse LLM response: \(String(decoding: data.prefix(500), as: UTF8.self))")
        }
        guard let message = ((object["choices"] as? [[String: Any]])?.first)?["message"] as? [String: Any] else {
            throw .message("No content in LLM response")
        }
        let reasoning = [message["reasoning"], message["reasoning_content"]].compactMap { $0 as? String }
        return Completion(content: (message["content"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                          reasoningStripped: reasoning.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
    }

    static func parseClaude(_ data: Data) throws(LLMError) -> Completion {
        guard let blocks = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["content"] as? [[String: Any]] else {
            throw .message("Failed to parse LLM response: \(String(decoding: data.prefix(500), as: UTF8.self))")
        }
        guard let text = blocks.first(where: { $0["type"] as? String == "text" })?["text"] as? String else {
            throw .message("No text content in LLM response")
        }
        let types = blocks.compactMap { $0["type"] as? String }
        return Completion(content: text.trimmingCharacters(in: .whitespacesAndNewlines),
                          reasoningStripped: types.contains("thinking") || types.contains("redacted_thinking"))
    }

    // MARK: HTTP

    /// POSTs JSON. Throws `.cancelled` when the task is cancelled, and on a non-2xx status unless `allowFailure`.
    func post(_ request: inout URLRequest, _ body: Data, allowFailure: Bool = false) async throws(LLMError) -> (Data, Int) {
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return try await send(request, allowFailure: allowFailure, prefix: "LLM API request failed with status")
    }

    func send(_ request: URLRequest, allowFailure: Bool = false, prefix: String) async throws(LLMError) -> (Data, Int) {
        guard !Task.isCancelled else { throw .cancelled }
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw Self.map(error)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if !allowFailure, !(200..<300).contains(status) {
            throw .message("\(prefix) \(status): \(String(decoding: data, as: UTF8.self))")
        }
        return (data, status)
    }

    static func map(_ error: any Error) -> LLMError {
        if error is CancellationError || (error as? URLError)?.code == .cancelled || Task.isCancelled { return .cancelled }
        if (error as? URLError)?.code == .timedOut { return .message("LLM request timed out after \(Int(timeout)) seconds") }
        return .message("Failed to send request to LLM: \(error.localizedDescription)")
    }

    // MARK: ChatGPT via Codex

    /// GUI launches get a minimal PATH, so also check common install dirs.
    static func findCodex() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let dirs = path + ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.npm-global/bin", "\(home)/.bun/bin"]
        return dirs.lazy.map { URL(fileURLWithPath: $0).appending(path: "codex") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Runs one prompt through `codex exec`, which bills the user's ChatGPT plan.
    static func codex(_ executable: URL, model: String, system: String, user: String) async throws(LLMError) -> Completion {
        // Empty working dir + read-only sandbox: the agent has nothing to touch.
        let work = FileManager.default.temporaryDirectory.appending(path: "meety-codex-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: work) }
        do { try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true) } catch {
            throw .message("Failed to create Codex work dir: \(error.localizedDescription)")
        }
        let output = work.appending(path: "summary.md")
        let prompt = "Answer directly with the requested output only. Do not run commands or edit files.\n\n# Instructions\n\(system)\n\n# Input\n\(user)"

        let process = Process()
        process.executableURL = executable
        process.arguments = ["exec", "--ephemeral", "--skip-git-repo-check", "--ignore-user-config",
                             "--ignore-rules", "-s", "read-only", "--color", "never", "-m", model, "-C", work.path, "-o", output.path, "-"]
        let stdin = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderr
        log.info("LLM request to ChatGPT via Codex CLI: model=\(model, privacy: .public)")

        let result: (status: Int32, stderr: Data)
        do {
            result = try await withThrowingTaskGroup { group in
                group.addTask { try await run(process, stdin: stdin, stderr: stderr, input: Data(prompt.utf8)) }
                group.addTask {
                    try await Task.sleep(for: .seconds(timeout))
                    throw LLMError.message("LLM request timed out after \(Int(timeout)) seconds")
                }
                defer { group.cancelAll() }
                return try await group.next()!
            }
        } catch let error as LLMError {
            throw error
        } catch {
            throw Task.isCancelled ? .cancelled : .message("Codex CLI failed: \(error.localizedDescription)")
        }

        guard result.status == 0 else {
            // Only the last lines: earlier stderr echoes the whole prompt (the transcript).
            let tail = String(decoding: result.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: "\n", omittingEmptySubsequences: false).suffix(5).joined(separator: "\n")
            throw .message("Codex CLI exited with \(result.status). Run `codex login` if you are signed out. \(tail)")
        }
        guard let content = try? String(contentsOf: output, encoding: .utf8) else { throw .message("Codex CLI returned no answer") }
        return Completion(content: content.trimmingCharacters(in: .whitespacesAndNewlines), reasoningStripped: false)
    }

    /// Runs the process to exit, feeding stdin and draining stderr concurrently so neither pipe fills.
    /// Cancelling the task terminates the process.
    @concurrent static func run(_ process: Process, stdin: Pipe, stderr: Pipe, input: Data) async throws -> (Int32, Data) {
        try await withTaskCancellationHandler {
            let exited = AsyncStream<Int32> { continuation in
                process.terminationHandler = { continuation.yield($0.terminationStatus); continuation.finish() }
            }
            try process.run()
            async let errors = (try? stderr.fileHandleForReading.readToEnd()) ?? Data()
            try? stdin.fileHandleForWriting.write(contentsOf: input) // fails only if codex exits early; its status says why
            try? stdin.fileHandleForWriting.close()
            var status: Int32 = -1
            for await code in exited { status = code }
            try Task.checkCancellation()
            return (status, await errors)
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }
}

func trimSlash(_ endpoint: String) -> String {
    endpoint.hasSuffix("/") ? String(endpoint.dropLast()) : endpoint
}

func json(_ object: [String: Any]) throws(LLMError) -> Data {
    do { return try JSONSerialization.data(withJSONObject: object) } catch { throw .message("Failed to encode request: \(error)") }
}

/// Older Ollama servers reject `reasoning_effort` (or `think: none`) with a 400/422 naming it.
func ollamaRejectsReasoningEffort(status: Int, body: String) -> Bool {
    guard status == 400 || status == 422, let data = body.data(using: .utf8),
          let value = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) else { return false }
    let object = value as? [String: Any]
    let error = object?["error"] as? [String: Any]
    let fields = [object?["param"], object?["field"], error?["param"], error?["field"]].compactMap { $0 as? String }
    if fields.contains(where: { $0.lowercased() == "reasoning_effort" }) { return true }
    let messages = [value as? String, object?["error"] as? String, object?["message"] as? String, error?["message"] as? String]
    return messages.compactMap { $0?.lowercased() }.contains { message in
        message.contains("reasoning_effort")
            || (message.contains("think value") && message.contains("none") && (message.contains("not supported") || message.contains("invalid")))
    }
}
