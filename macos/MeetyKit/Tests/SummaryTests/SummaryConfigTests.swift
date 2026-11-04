import Core
import Foundation
import Testing
@testable import Summary

@Suite struct SummaryConfigTests {
    let store: Store
    let keychain = Keychain(service: "com.meetily.ai.tests.\(UUID().uuidString)")

    init() throws { store = try Store(path: scratch().appending(path: "meeting_minutes.sqlite").path) }

    func clean() { for provider in Keychain.providers { try? keychain.set(nil, for: provider) } }

    @Test func `an empty database loads the built-in provider with no model`() async throws {
        let config = try await SummaryConfig.load(store: store, keychain: keychain)
        #expect(config.provider == .builtin && config.model.isEmpty && config.apiKey.isEmpty)
    }

    @Test func `saving keeps the key in the keychain, not the database`() async throws {
        defer { clean() }
        try await SummaryConfig(provider: .claude, model: "claude-opus-5-5", apiKey: "sk-ant").save(store: store, keychain: keychain)
        let row = try #require(try await store.modelConfig())
        #expect(row.provider == "claude" && row.model == "claude-opus-5-5" && row.anthropicApiKey == nil)
        #expect(keychain.get("claude") == "sk-ant")
        let loaded = try await SummaryConfig.load(store: store, keychain: keychain)
        #expect(loaded.provider == .claude && loaded.model == "claude-opus-5-5" && loaded.apiKey == "sk-ant")
    }

    @Test func `the custom endpoint round-trips and keeps a legacy key in its JSON`() async throws {
        defer { clean() }
        try await store.saveCustomOpenAIConfig(#"{"endpoint":"http://old","apiKey":"legacy","model":"x"}"#)
        var config = SummaryConfig(provider: .customOpenAI, model: "llama3", apiKey: "sk-custom")
        config.customEndpoint = "http://localhost:8080/v1"
        config.maxTokens = 2048
        config.temperature = 0.3
        config.topP = 0.9
        try await config.save(store: store, keychain: keychain)

        let loaded = try await SummaryConfig.load(store: store, keychain: keychain)
        #expect(loaded == config)
        let json = try #require(try await store.modelConfig()?.customOpenAIConfig)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(object["apiKey"] as? String == "legacy") // the Tauri app still reads it until cutover (D10)
        #expect(object["endpoint"] as? String == "http://localhost:8080/v1")
    }

    @Test func `ollama keeps its endpoint and needs no key`() async throws {
        var config = SummaryConfig(provider: .ollama, model: "llama3.2")
        config.ollamaEndpoint = "http://studio.local:11434"
        try await config.save(store: store, keychain: keychain)
        let loaded = try await SummaryConfig.load(store: store, keychain: keychain)
        #expect(loaded.ollamaEndpoint == "http://studio.local:11434" && loaded.provider == .ollama)
    }

    @Test func `the old local-llama id loads as built-in`() async throws {
        try await store.saveModelConfig(provider: "local-llama", model: "gemma3:1b", whisperModel: "large-v3", ollamaEndpoint: nil)
        let loaded = try await SummaryConfig.load(store: store, keychain: keychain)
        #expect(loaded.provider == .builtin && loaded.model == "gemma3:1b")
    }

    @Test(arguments: [
        (SummaryConfig(provider: .openai, model: ""), "Choose a model."),
        (SummaryConfig(provider: .builtin, model: "Qwen 3.5 2B"), "Choose a built-in model from the list, for example qwen3.5:2b."),
        (SummaryConfig(provider: .openai, model: "gpt-6-astra"), "Enter an API key for this provider."),
        (SummaryConfig(provider: .ollama, model: "m", ollamaEndpoint: "localhost:11434"), "Invalid Ollama endpoint URL. Must start with http:// or https://"),
        (SummaryConfig(provider: .customOpenAI, model: "m"), "Enter the endpoint URL. It must start with http:// or https://"),
        (SummaryConfig(provider: .customOpenAI, model: "m", customEndpoint: "http://h", temperature: 3), "Temperature must be between 0 and 2."),
        (SummaryConfig(provider: .customOpenAI, model: "m", customEndpoint: "http://h", topP: 1.5), "Top P must be between 0 and 1."),
        (SummaryConfig(provider: .customOpenAI, model: "m", customEndpoint: "http://h", maxTokens: 0), "Max tokens must be positive."),
    ])
    func `invalid settings are refused`(config: SummaryConfig, message: String) async throws {
        #expect(throws: LLMError.message(message)) { try config.validate() }
        await #expect(throws: LLMError.message(message)) { try await config.save(store: store, keychain: keychain) }
        #expect(try await store.modelConfig() == nil)
    }

    @Test func `built-in and ChatGPT need no key`() throws {
        try SummaryConfig(provider: .builtin, model: "gemma4:e2b").validate()
        try SummaryConfig(provider: .chatgpt, model: "gpt-6-astra").validate()
    }
}
