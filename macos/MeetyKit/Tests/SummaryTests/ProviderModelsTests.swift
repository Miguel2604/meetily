import Foundation
import Synchronization
import Testing
@testable import Summary

@Suite struct ProviderModelsTests {
    @Test func `OpenAI lists chat models only and falls back without a key or on errors`() async throws {
        let stub = Stub { _ in
            Reply(200, #"{"data":[{"id":"gpt-6-astra","object":"model","owned_by":"x"},{"id":"text-embedding-3","object":"model","owned_by":"x"},{"id":"gpt-4o-realtime","object":"model","owned_by":"x"},{"id":"o3-mini","object":"model","owned_by":"x"},{"id":"dall-e-3","object":"model","owned_by":"x"}]}"#)
        }
        let client = LLMClient(session: stub.session)
        #expect(try await client.models(.openai, apiKey: " k ").map(\.id) == ["gpt-6-astra", "o3-mini"])
        #expect(stub.requests.first?.headers["Authorization"] == "Bearer k")
        #expect(try await client.models(.openai, apiKey: "").map(\.id) == ["gpt-6-astra", "gpt-6.1-sol", "gpt-6.1-terra", "gpt-6-luna", "gpt-5.5"])
        let failing = LLMClient(session: Stub { _ in Reply(500) }.session)
        #expect(try await failing.models(.openai, apiKey: "k").count == 5)
    }

    @Test func `Groq drops audio, embedding and guard models`() async throws {
        let stub = Stub { _ in
            Reply(200, #"{"data":[{"id":"llama-3.3-70b-versatile","owned_by":"Meta"},{"id":"whisper-large-v3"},{"id":"llama-guard-4"},{"id":"nomic-embed"}]}"#)
        }
        #expect(try await LLMClient(session: stub.session).models(.groq, apiKey: "k").map(\.id) == ["llama-3.3-70b-versatile"])
        #expect(stub.requests.first?.url.absoluteString == "https://api.groq.com/openai/v1/models")
        #expect(try await LLMClient(session: stub.session).models(.groq, apiKey: nil).first?.id == "openai/gpt-oss-120b")
    }

    @Test func `Anthropic lists Claude models with display names`() async throws {
        let stub = Stub { _ in Reply(200, #"{"data":[{"id":"claude-opus-5-5","display_name":"Claude Opus 5.5"},{"id":"other"}]}"#) }
        let models = try await LLMClient(session: stub.session).models(.claude, apiKey: "sk")
        #expect(models == [RemoteModel(id: "claude-opus-5-5", name: "Claude Opus 5.5")])
        #expect(stub.requests.first?.headers["x-api-key"] == "sk")
        #expect(stub.requests.first?.headers["anthropic-version"] == "2023-06-01")
        let fallback = try await LLMClient(session: stub.session).models(.claude, apiKey: nil)
        #expect(fallback.map(\.id) == ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5", "claude-fable-5-1"])
        #expect(fallback.first?.name == "Claude Opus 5.5")
    }

    @Test func `OpenRouter lists every model and reports failures`() async throws {
        let stub = Stub { _ in Reply(200, #"{"data":[{"id":"a/b","name":"B","context_length":8000,"top_provider":{"context_length":16000}},{"id":"c/d"}]}"#) }
        let models = try await LLMClient(session: stub.session).models(.openrouter, apiKey: nil)
        #expect(models == [RemoteModel(id: "a/b", name: "B", contextLength: 16000), RemoteModel(id: "c/d", name: "Unknown")])
        await #expect(throws: LLMError.message("HTTP request failed with status: 503")) {
            try await LLMClient(session: Stub { _ in Reply(503) }.session).models(.openrouter, apiKey: nil)
        }
    }

    @Test func `Ollama lists tags with human sizes and rejects bad endpoints`() async throws {
        let stub = Stub { _ in
            Reply(200, #"{"models":[{"name":"llama3:8b","model":"llama3:8b","modified_at":"2026-01-01T00:00:00Z","size":4920000000},{"name":"tiny","model":"tiny","modified_at":"x","size":512}]}"#)
        }
        let models = try await LLMClient(session: stub.session).models(.ollama, endpoint: "http://box:11434")
        #expect(models == [RemoteModel(id: "llama3:8b", name: "llama3:8b", size: "4.6 GB"), RemoteModel(id: "tiny", name: "tiny", size: "512 B")])
        #expect(stub.requests.first?.url.absoluteString == "http://box:11434/api/tags")
        await #expect(throws: LLMError.self) { try await LLMClient(session: stub.session).models(.ollama, endpoint: "box:11434") }
        let empty = Stub { _ in Reply(200, #"{"models":[]}"#) }
        await #expect(throws: LLMError.message("No models found on the Ollama server. Please pull models using 'ollama pull <model>'.")) {
            try await LLMClient(session: empty.session).models(.ollama, endpoint: "http://box:11434")
        }
    }

    @Test func `the ollama list CLI output parses into models`() {
        let output = """
        NAME            ID              SIZE      MODIFIED
        llama3:8b       365c0bd3c000    4.7 GB    3 weeks ago
        bad line
        """
        #expect(parseOllamaList(output) == [RemoteModel(id: "llama3:8b", name: "llama3:8b", size: "4.7 GB")])
    }

    @Test func `pulling an Ollama model streams percent progress and surfaces stream errors`() async throws {
        let lines = [#"{"status":"pulling"}"#, #"{"completed":50,"total":200}"#, #"{"completed":200,"total":200}"#, ""].joined(separator: "\n")
        let stub = Stub { _ in Reply(200, lines) }
        let seen = Mutex<[Int]>([])
        try await LLMClient(session: stub.session).pullOllama("llama3", endpoint: nil) { p in seen.withLock { $0.append(p) } }
        #expect(seen.withLock { $0 } == [25, 100])
        #expect(stub.requests.first?.url.absoluteString == "http://localhost:11434/api/pull")
        #expect(stub.requests.first?.json["name"] as? String == "llama3")

        let failing = Stub { _ in Reply(200, #"{"error":"pull model manifest: file does not exist"}"# + "\n") }
        await #expect(throws: LLMError.message("Ollama error: pull model manifest: file does not exist")) {
            try await LLMClient(session: failing.session).pullOllama("nope", endpoint: nil) { _ in }
        }
    }

    @Test func `deleting an Ollama model sends DELETE with the name`() async throws {
        let stub = Stub { _ in Reply(200) }
        try await LLMClient(session: stub.session).deleteOllama("llama3", endpoint: "http://box:1")
        #expect(stub.requests.first?.method == "DELETE")
        #expect(stub.requests.first?.url.absoluteString == "http://box:1/api/delete")
        #expect(stub.requests.first?.json["name"] as? String == "llama3")
        await #expect(throws: LLMError.message("Failed to delete model (HTTP 404): missing")) {
            try await LLMClient(session: Stub { _ in Reply(404, "missing") }.session).deleteOllama("x", endpoint: nil)
        }
    }

    @Test(arguments: [
        (#"{"model_info":{"gemma3.context_length":131072},"details":{"family":"gemma3"},"modelfile":""}"#, 131072),
        (#"{"model_info":{},"details":{"family":"x"},"modelfile":"FROM x\nPARAMETER num_ctx 32768\n"}"#, 32768),
        (#"{"model_info":{},"details":{"family":"mistral"},"modelfile":""}"#, 8192),
        (#"{"details":{"family":"unknown"},"modelfile":""}"#, 4000),
    ])
    func `the Ollama context size comes from model info, then num_ctx, then the family`(body: String, size: Int) async {
        let stub = Stub { _ in Reply(200, body) }
        #expect(await LLMClient(session: stub.session).ollamaContextSize("m", endpoint: nil) == size)
    }

    @Test func `an unknown Ollama model falls back to the family in its name`() async {
        #expect(await LLMClient(session: Stub { _ in Reply(404) }.session).ollamaContextSize("qwen2.5:7b", endpoint: nil) == 8192)
        #expect(await LLMClient(session: Stub { _ in Reply(404) }.session).ollamaContextSize("zzz", endpoint: nil) == 4000)
    }

    @Test func `the custom endpoint test validates an OpenAI-shaped reply`() async throws {
        let ok = Stub { _ in Reply(200, #"{"choices":[{"message":{"content":""}}]}"#) }
        try await LLMClient(session: ok.session).testCustomEndpoint("http://llm.local/v1/", apiKey: "k", model: "m")
        let seen = try #require(ok.requests.first)
        #expect(seen.url.absoluteString == "http://llm.local/v1/chat/completions")
        #expect(seen.headers["Authorization"] == "Bearer k")
        #expect(seen.json["max_tokens"] as? Int == 5)

        let reasoning = Stub { _ in Reply(200, #"{"choices":[{"message":{"reasoning_content":"x"}}]}"#) }
        try await LLMClient(session: reasoning.session).testCustomEndpoint("http://a", apiKey: nil, model: "m")
        #expect(reasoning.requests.first?.headers["Authorization"] == nil)

        await #expect(throws: LLMError.message("Endpoint must start with http:// or https://")) {
            try await LLMClient(session: ok.session).testCustomEndpoint("llm.local", apiKey: nil, model: "m")
        }
        await #expect(throws: LLMError.self) {
            try await LLMClient(session: Stub { _ in Reply(200, #"{"data":1}"#) }.session).testCustomEndpoint("http://a", apiKey: nil, model: "m")
        }
        await #expect(throws: LLMError.message("Connection failed with status 500: boom")) {
            try await LLMClient(session: Stub { _ in Reply(500, "boom") }.session).testCustomEndpoint("http://a", apiKey: nil, model: "m")
        }
    }
}
