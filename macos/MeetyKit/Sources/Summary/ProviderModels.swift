import Foundation

/// A model a provider offers, for the settings picker.
public struct RemoteModel: Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var contextLength: Int?
    /// Ollama download size, e.g. "4.6 GB".
    public var size: String?

    public init(id: String, name: String? = nil, contextLength: Int? = nil, size: String? = nil) {
        self.id = id
        self.name = name ?? id
        self.contextLength = contextLength
        self.size = size
    }
}

// Model listing (`openai.rs`, `groq.rs`, `anthropic.rs`, `openrouter.rs`, `ollama.rs`) and the custom endpoint test.
// shortcut: no 5-minute model cache; the settings window lists once per open. Add one if the picker refetches often.
extension LLMClient {
    static let openAIFallback = ["gpt-6-astra", "gpt-6.1-sol", "gpt-6.1-terra", "gpt-6-luna", "gpt-5.5"].map { RemoteModel(id: $0) }
    static let groqFallback = ["openai/gpt-oss-120b", "llama-3.3-70b-versatile", "openai/gpt-oss-20b", "llama-3.1-8b-instant"].map { RemoteModel(id: $0) }
    static let claudeFallback = [("claude-opus-5-5", "Claude Opus 5.5"), ("claude-sonnet-5-5", "Claude Sonnet 5.5"),
                                 ("claude-haiku-5-5", "Claude Haiku 5.5"), ("claude-fable-5-1", "Claude Fable 5.1")]
        .map { RemoteModel(id: $0, name: $1) }

    /// Models for a provider. OpenAI, Groq and Claude fall back to a fixed list without a key or on any failure.
    /// Built-in AI has its own catalog (`BuiltInModel`); custom endpoints take a typed model name.
    public func models(_ provider: Provider, apiKey: String? = nil, endpoint: String? = nil) async throws(LLMError) -> [RemoteModel] {
        let key = apiKey?.trimmingCharacters(in: .whitespaces) ?? ""
        switch provider {
        case .openai, .chatgpt:
            guard provider == .openai, !key.isEmpty else { return Self.openAIFallback }
            let chat = try? await list("https://api.openai.com/v1/models", headers: ["Authorization": "Bearer \(key)"]).filter { m in
                let id = m.id.lowercased()
                return ["gpt-", "o1-", "o3-", "o4-", "chatgpt-"].contains { id.hasPrefix($0) }
                    && !["embedding", "tts", "whisper", "dall-e", "babbage", "davinci", "instruct", "realtime", "audio"].contains { id.contains($0) }
            }
            return chat.flatMap { $0.isEmpty ? nil : $0 } ?? Self.openAIFallback
        case .groq:
            guard !key.isEmpty else { return Self.groqFallback }
            let chat = try? await list("https://api.groq.com/openai/v1/models", headers: ["Authorization": "Bearer \(key)"]).filter { m in
                !["whisper", "embed", "guard", "tool-use"].contains { m.id.lowercased().contains($0) }
            }
            return chat.flatMap { $0.isEmpty ? nil : $0 } ?? Self.groqFallback
        case .claude:
            guard !key.isEmpty else { return Self.claudeFallback }
            let chat = try? await list("https://api.anthropic.com/v1/models", headers: ["x-api-key": key, "anthropic-version": "2023-06-01"])
                .filter { $0.id.lowercased().hasPrefix("claude-") }
            return chat.flatMap { $0.isEmpty ? nil : $0 } ?? Self.claudeFallback
        case .openrouter:
            let request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/models")!)
            let (data, status) = try await send(request, allowFailure: true, prefix: "")
            guard status == 200 else { throw .message("HTTP request failed with status: \(status)") }
            guard let rows = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["data"] as? [[String: Any]] else {
                throw .message("Failed to parse JSON response")
            }
            return rows.compactMap { row in
                guard let id = row["id"] as? String else { return nil }
                let context = (row["top_provider"] as? [String: Any])?["context_length"] as? Int ?? row["context_length"] as? Int
                return RemoteModel(id: id, name: row["name"] as? String ?? "Unknown", contextLength: context)
            }
        case .ollama:
            return try await ollamaModels(endpoint: endpoint)
        case .builtin, .customOpenAI:
            return []
        }
    }

    /// GETs an OpenAI/Anthropic-style `{"data": [{"id", "display_name"?}]}` list with a 5 s timeout.
    private func list(_ url: String, headers: [String: String]) async throws(LLMError) -> [RemoteModel] {
        var request = URLRequest(url: URL(string: url)!, timeoutInterval: 5)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let (data, _) = try await send(request, prefix: "HTTP")
        guard let rows = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["data"] as? [[String: Any]] else {
            throw .message("Failed to parse model list")
        }
        return rows.compactMap { row in (row["id"] as? String).map { RemoteModel(id: $0, name: row["display_name"] as? String) } }
    }

    // MARK: Ollama

    private func ollamaModels(endpoint: String?) async throws(LLMError) -> [RemoteModel] {
        let base = endpoint.flatMap { $0.isEmpty ? nil : $0 } ?? Self.defaultOllama
        guard base.hasPrefix("http://") || base.hasPrefix("https://") else {
            throw .message("Invalid endpoint: URL must start with http:// or https://. Please check the URL format.")
        }
        var lastError = LLMError.message("")
        for attempt in 0...2 {
            if attempt > 0 { try? await Task.sleep(for: .milliseconds(300 << (attempt - 1))) }
            do throws(LLMError) {
                let (data, _) = try await send(URLRequest(url: URL(string: "\(base)/api/tags")!, timeoutInterval: 3), prefix: "Ollama server error: HTTP")
                guard let rows = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["models"] as? [[String: Any]] else {
                    throw LLMError.message("Failed to parse server response")
                }
                let models = rows.compactMap { row in
                    (row["name"] as? String).map { RemoteModel(id: $0, size: formatSize(row["size"] as? Int64 ?? 0)) }
                }
                guard !models.isEmpty else { throw LLMError.message(Self.noOllamaModels) }
                return models
            } catch {
                lastError = error
                if error == .cancelled || error == .message(Self.noOllamaModels) || "\(error)".contains("404") { throw error }
            }
        }
        // The server may be down while the CLI still answers (local installs only).
        let local = endpoint.map { $0.isEmpty || $0.contains("localhost") || $0.contains("127.0.0.1") || $0.contains("::1") } ?? true
        guard local, let models = try? await Self.ollamaCLI(), !models.isEmpty else { throw lastError }
        return models
    }

    static let noOllamaModels = "No models found on the Ollama server. Please pull models using 'ollama pull <model>'."

    @concurrent private static func ollamaCLI() async throws -> [RemoteModel] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["ollama", "list"]
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = (environment["PATH"].map { $0 + ":" } ?? "") + "/opt/homebrew/bin:/usr/local/bin"
        process.environment = environment
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = try out.fileHandleForReading.readToEnd() ?? Data()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return [] }
        return parseOllamaList(String(decoding: data, as: UTF8.self))
    }

    /// Pulls a model, reporting whole-percent progress as it changes.
    public func pullOllama(_ name: String, endpoint: String?, progress: @Sendable (Int) -> Void) async throws(LLMError) {
        let base = endpoint ?? Self.defaultOllama
        var request = URLRequest(url: URL(string: "\(base)/api/pull")!, timeoutInterval: 600)
        request.httpMethod = "POST"
        request.httpBody = try json(["name": name, "stream": true])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            let (bytes, response) = try await session.bytes(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                var body = Data()
                for try await byte in bytes { body.append(byte) }
                throw LLMError.message("Failed to pull model (HTTP \(status)): \(String(decoding: body, as: UTF8.self))")
            }
            var last = 0
            for try await line in bytes.lines {
                guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
                if let error = object["error"] as? String { throw LLMError.message("Ollama error: \(error)") }
                if let completed = object["completed"] as? Double, let total = object["total"] as? Double, total > 0 {
                    let percent = Int(completed / total * 100)
                    if percent != last { progress(percent); last = percent }
                }
            }
        } catch let error as LLMError {
            throw error
        } catch {
            throw Self.map(error)
        }
    }

    public func deleteOllama(_ name: String, endpoint: String?) async throws(LLMError) {
        var request = URLRequest(url: URL(string: "\(endpoint ?? Self.defaultOllama)/api/delete")!, timeoutInterval: 30)
        request.httpMethod = "DELETE"
        request.httpBody = try json(["name": name])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, status) = try await send(request, allowFailure: true, prefix: "")
        guard (200..<300).contains(status) else { throw .message("Failed to delete model (HTTP \(status)): \(String(decoding: data, as: UTF8.self))") }
    }

    /// Port of `ollama/metadata.rs`: context window from `/api/show`, else `num_ctx`, else the model family; 4000 last.
    public func ollamaContextSize(_ model: String, endpoint: String?) async -> Int {
        let families = [("llama", 4096), ("mistral", 8192), ("phi", 2048), ("qwen", 8192), ("gemma", 8192),
                        ("codellama", 16384), ("deepseek", 16384), ("neural-chat", 4096)]
        func byFamily(_ name: String) -> Int? { families.first { name.lowercased().contains($0.0) }?.1 }

        var request = URLRequest(url: URL(string: "\(endpoint ?? Self.defaultOllama)/api/show")!, timeoutInterval: 5)
        request.httpMethod = "POST"
        request.httpBody = try? json(["name": model, "verbose": true])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        guard let (data, status) = try? await send(request, allowFailure: true, prefix: ""), status == 200,
              let show = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return byFamily(model) ?? 4000 }
        let family = (show["details"] as? [String: Any])?["family"] as? String ?? ""
        let info = show["model_info"] as? [String: Any] ?? [:]
        if let size = ["\(family).context_length", "\(family).context_size", "context_length", "context_size"].lazy.compactMap({ info[$0] as? Int }).first {
            return size
        }
        if let match = (show["modelfile"] as? String ?? "").firstMatch(of: /PARAMETER\s+num_ctx\s+(\d+)/), let size = Int(match.1) {
            return size
        }
        return byFamily(family.isEmpty ? model : family) ?? 4000
    }

    // MARK: Custom endpoint

    /// Sends a 5-token "Hi" and checks the reply is OpenAI-shaped.
    public func testCustomEndpoint(_ endpoint: String, apiKey: String?, model: String) async throws(LLMError) {
        guard endpoint.hasPrefix("http://") || endpoint.hasPrefix("https://"), let url = URL(string: "\(trimSlash(endpoint))/chat/completions") else {
            throw .message("Endpoint must start with http:// or https://")
        }
        var request = URLRequest(url: url, timeoutInterval: 30)
        if let key = apiKey?.trimmingCharacters(in: .whitespaces), !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        let body = try json(["model": model, "messages": [["role": "user", "content": "Hi"]], "max_tokens": 5])
        let (data, status) = try await post(&request, body, allowFailure: true)
        let text = String(decoding: data, as: UTF8.self)
        guard (200..<300).contains(status) else { throw .message("Connection failed with status \(status): \(text)") }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw .message("Endpoint is reachable but returned invalid JSON. Response: \(text)")
        }
        let message = ((object["choices"] as? [[String: Any]])?.first)?["message"] as? [String: Any]
        guard message?["content"] != nil || message?["reasoning_content"] != nil else {
            throw .message("Endpoint is reachable but doesn't appear to be OpenAI-compatible. Response is missing 'choices' array or 'message.content' / 'message.reasoning_content' field.")
        }
    }
}

func formatSize(_ bytes: Int64) -> String {
    let value = Double(bytes)
    return switch bytes {
    case ..<1024: "\(bytes) B"
    case ..<(1 << 20): String(format: "%.1f KB", value / 1024)
    case ..<(1 << 30): String(format: "%.1f MB", value / 1_048_576)
    default: String(format: "%.1f GB", value / 1_073_741_824)
    }
}

/// `ollama list` rows: NAME ID SIZE UNIT MODIFIED...
func parseOllamaList(_ output: String) -> [RemoteModel] {
    output.split(separator: "\n").dropFirst().compactMap { line in
        let parts = line.split(whereSeparator: \.isWhitespace)
        return parts.count >= 4 ? RemoteModel(id: String(parts[0]), size: "\(parts[2]) \(parts[3])") : nil
    }
}
