import Foundation
import Testing
@testable import Summary

func request(_ provider: Provider, model: String = "model", key: String = "", endpoint: String? = nil) -> LLMRequest {
    LLMRequest(provider: provider, model: model, apiKey: key, system: "sys", user: "user",
               ollamaEndpoint: provider == .ollama ? endpoint : nil, customEndpoint: provider == .customOpenAI ? endpoint : nil)
}

let completionJSON = #"{"choices":[{"message":{"content":"  Meeting summary.  "}}]}"#

@Suite struct LLMClientTests {
    // Ports of the llm_client.rs unit tests.

    @Test func `only Ollama disables reasoning and custom sampling is preserved`() throws {
        for provider in [Provider.openai, .groq, .openrouter, .customOpenAI] {
            #expect(try chatBody(request(provider))["reasoning_effort"] == nil)
        }
        #expect(try chatBody(request(.ollama))["reasoning_effort"] as? String == "none")
        var custom = request(.customOpenAI)
        (custom.maxTokens, custom.temperature, custom.topP) = (12, 0.3, 0.8)
        let body = try chatBody(custom)
        #expect(body["max_tokens"] as? Int == 12)
        #expect(body["temperature"] as? Double == 0.3)
        #expect(body["top_p"] as? Double == 0.8)
        var openai = custom
        openai.provider = .openai
        #expect(try chatBody(openai)["max_tokens"] == nil) // sampling is only sent to custom endpoints
        let messages = try #require(body["messages"] as? [[String: String]])
        #expect(messages == [["role": "system", "content": "sys"], ["role": "user", "content": "user"]])
    }

    @Test(arguments: [#"{"reasoning_content":"private"}"#, #"{"content":null,"reasoning_content":"private"}"#])
    func `compatible reasoning is separate from visible content`(message: String) throws {
        let completion = try LLMClient.parseChat(Data(#"{"choices":[{"message":\#(message)}]}"#.utf8))
        #expect(completion == Completion(content: "", reasoningStripped: true))
    }

    @Test func `legacy Ollama rejection requires a compatible error`() {
        #expect(ollamaRejectsReasoningEffort(status: 400, body: #"{"error":{"param":"reasoning_effort"}}"#))
        #expect(ollamaRejectsReasoningEffort(status: 422, body: #"{"message":"Unsupported parameter 'ReAsOnInG_EfFoRt'."}"#))
        #expect(ollamaRejectsReasoningEffort(status: 400, body: #"{"error":"think value \"none\" is not supported for this model"}"#))
        #expect(!ollamaRejectsReasoningEffort(status: 400, body: #"{"message":"invalid model"}"#))
        #expect(!ollamaRejectsReasoningEffort(status: 401, body: #"{"error":{"param":"reasoning_effort"}}"#))
        #expect(!ollamaRejectsReasoningEffort(status: 500, body: #"{"error":"think value \"none\" is not supported"}"#))
    }

    @Test func `legacy Ollama retry without reasoning_effort returns the completion`() async throws {
        let stub = Stub { seen in
            seen.json["reasoning_effort"] != nil ? Reply(400, #"{"error":{"param":"reasoning_effort"}}"#) : Reply(200, completionJSON)
        }
        let completion = try await LLMClient(session: stub.session).complete(request(.ollama, endpoint: "http://box:11434"))
        #expect(completion == Completion(content: "Meeting summary.", reasoningStripped: false))
        #expect(stub.requests.map(\.url.absoluteString) == Array(repeating: "http://box:11434/v1/chat/completions", count: 2))
        #expect(stub.requests[1].json["reasoning_effort"] == nil)
    }

    @Test func `cancelling during the Ollama retry returns promptly`() async throws {
        let stub = Stub { seen in
            seen.json["reasoning_effort"] != nil
                ? Reply(400, #"{"error":{"param":"reasoning_effort"}}"#) : Reply(200, completionJSON, delay: .seconds(30))
        }
        let task = Task { try await LLMClient(session: stub.session).complete(request(.ollama)) }
        while stub.requests.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
        let clock = ContinuousClock.now
        task.cancel()
        await #expect(throws: LLMError.cancelled) { try await task.value }
        #expect(ContinuousClock.now - clock < .seconds(1))
    }

    @Test func `a cancelled task never sends the request`() async throws {
        let stub = Stub { _ in Reply(200, completionJSON) }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await LLMClient(session: stub.session).complete(request(.openai))
        }
        await #expect(throws: LLMError.cancelled) { try await task.value }
        #expect(stub.requests.isEmpty)
    }

    @Test func `Claude responses use the exact text block type`() throws {
        let body = #"{"content":[{"type":"analysis","text":"not visible"},{"type":"thinking","thinking":"private"},{"type":"text","text":"Meeting summary."}]}"#
        #expect(try LLMClient.parseClaude(Data(body.utf8)) == Completion(content: "Meeting summary.", reasoningStripped: true))
        #expect(throws: LLMError.self) { try LLMClient.parseClaude(Data(#"{"content":[]}"#.utf8)) }
    }

    @Test func `the Codex bridge sends the prompt on stdin and reads the last message`() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stub = dir.appending(path: "codex")
        // Echoes stdin into the -o file; exits 3 when the model is "fail".
        try """
        #!/bin/sh
        case "$*" in *' -m fail '*) echo 'not logged in' >&2; exit 3;; esac
        while [ "$1" != "-o" ]; do shift; done
        cat > "$2"
        """.write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)

        let completion = try await LLMClient.codex(stub, model: "m", system: "SYS", user: "USER")
        #expect(completion.content.contains("# Instructions\nSYS"))
        #expect(completion.content.hasSuffix("# Input\nUSER"))
        await #expect { try await LLMClient.codex(stub, model: "fail", system: "SYS", user: "USER") } throws: {
            "\($0)".contains("not logged in")
        }
    }

    // Request shape per provider.

    @Test(arguments: [
        (Provider.openai, "https://api.openai.com/v1/chat/completions"),
        (.groq, "https://api.groq.com/openai/v1/chat/completions"),
        (.openrouter, "https://openrouter.ai/api/v1/chat/completions"),
        (.ollama, "http://localhost:11434/v1/chat/completions"),
    ])
    func `OpenAI-compatible providers post to their endpoint with a bearer key`(provider: Provider, url: String) async throws {
        let stub = Stub { _ in Reply(200, completionJSON) }
        _ = try await LLMClient(session: stub.session).complete(request(provider, key: "k"))
        let seen = try #require(stub.requests.first)
        #expect(seen.method == "POST")
        #expect(seen.url.absoluteString == url)
        #expect(seen.headers["Authorization"] == "Bearer k")
        #expect(seen.headers["Content-Type"] == "application/json")
    }

    @Test func `the custom endpoint trims its trailing slash and is required`() async throws {
        let stub = Stub { _ in Reply(200, completionJSON) }
        let client = LLMClient(session: stub.session)
        _ = try await client.complete(request(.customOpenAI, endpoint: "http://llm.local/v1/"))
        #expect(stub.requests.first?.url.absoluteString == "http://llm.local/v1/chat/completions")
        await #expect(throws: LLMError.message("Custom OpenAI endpoint not configured")) {
            try await client.complete(request(.customOpenAI))
        }
    }

    @Test func `Claude uses the Messages API with its own headers`() async throws {
        let stub = Stub { _ in Reply(200, #"{"content":[{"type":"text","text":" Done "}]}"#) }
        let completion = try await LLMClient(session: stub.session).complete(request(.claude, model: "claude-opus-5-5", key: "sk-ant"))
        #expect(completion.content == "Done")
        let seen = try #require(stub.requests.first)
        #expect(seen.url.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(seen.headers["x-api-key"] == "sk-ant")
        #expect(seen.headers["anthropic-version"] == "2023-06-01")
        #expect(seen.headers["Authorization"] == nil)
        #expect(seen.json["system"] as? String == "sys")
        #expect(seen.json["max_tokens"] as? Int == 8192)
        #expect(seen.json["messages"] as? [[String: String]] == [["role": "user", "content": "user"]])
    }

    @Test func `HTTP failures carry the status and body`() async throws {
        let stub = Stub { _ in Reply(401, "bad key") }
        await #expect(throws: LLMError.message("LLM API request failed with status 401: bad key")) {
            try await LLMClient(session: stub.session).complete(request(.openai))
        }
    }

    @Test func `provider ids parse case-insensitively with the legacy aliases`() {
        #expect(Provider(id: "OpenAI") == .openai)
        #expect(Provider(id: "local-llama") == .builtin)
        #expect(Provider(id: "localllama") == .builtin)
        #expect(Provider(id: "builtin-ai") == .builtin)
        #expect(Provider(id: "custom-openai") == .customOpenAI)
        #expect(Provider(id: "chatgpt") == .chatgpt)
        #expect(Provider(id: "gemini") == nil)
    }
}

func chatBody(_ request: LLMRequest) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: LLMClient.chatBody(request)) as? [String: Any])
}
