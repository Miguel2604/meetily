import Core
import Foundation

/// The summary provider as Settings edits it: the `settings` row plus the provider's key in the Keychain (D10).
public struct SummaryConfig: Sendable, Equatable {
    public var provider: Provider
    public var model: String
    public var apiKey: String
    /// Empty uses `LLMClient.defaultOllama`.
    public var ollamaEndpoint: String
    public var customEndpoint: String
    public var maxTokens: Int?
    public var temperature: Double?
    public var topP: Double?

    public init(provider: Provider, model: String, apiKey: String = "", ollamaEndpoint: String = "", customEndpoint: String = "",
                maxTokens: Int? = nil, temperature: Double? = nil, topP: Double? = nil) {
        self.provider = provider
        self.model = model
        self.apiKey = apiKey
        self.ollamaEndpoint = ollamaEndpoint
        self.customEndpoint = customEndpoint
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.topP = topP
    }

    /// Providers that refuse to run without a key.
    public static let keyed: Set<Provider> = [.openai, .claude, .groq, .openrouter]

    public var takesKey: Bool { Self.keyed.contains(provider) || provider == .ollama || provider == .customOpenAI }

    /// Off the main actor, like `save`: a keychain read can block on an access prompt.
    @concurrent public static func load(store: Store, keychain: Keychain = Keychain()) async throws -> SummaryConfig {
        let row = try await store.modelConfig()
        let provider = row.flatMap { Provider(id: $0.provider) } ?? .builtin
        let custom = customJSON(row)
        var config = SummaryConfig(provider: provider, model: row?.model ?? "", ollamaEndpoint: row?.ollamaEndpoint ?? "",
                                   customEndpoint: custom["endpoint"] as? String ?? "", maxTokens: custom["maxTokens"] as? Int,
                                   temperature: custom["temperature"] as? Double, topP: custom["topP"] as? Double)
        if config.takesKey { config.apiKey = keychain.get(provider.rawValue) ?? "" }
        return config
    }

    public func validate() throws(LLMError) {
        func web(_ url: String) -> Bool { url.hasPrefix("http://") || url.hasPrefix("https://") }
        guard !model.trimmingCharacters(in: .whitespaces).isEmpty else { throw .message("Choose a model.") }
        if provider == .builtin, BuiltInModel.named(model.trimmingCharacters(in: .whitespaces)) == nil { // the box takes free text
            throw .message("Choose a built-in model from the list, for example \(BuiltInModel.catalog[0].name).")
        }
        if Self.keyed.contains(provider), apiKey.trimmingCharacters(in: .whitespaces).isEmpty {
            throw .message("Enter an API key for this provider.")
        }
        if provider == .ollama, !ollamaEndpoint.isEmpty, !web(ollamaEndpoint) {
            throw .message("Invalid Ollama endpoint URL. Must start with http:// or https://")
        }
        guard provider == .customOpenAI else { return }
        guard web(customEndpoint) else { throw .message("Enter the endpoint URL. It must start with http:// or https://") }
        if let temperature, !(0...2).contains(temperature) { throw .message("Temperature must be between 0 and 2.") }
        if let topP, !(0...1).contains(topP) { throw .message("Top P must be between 0 and 1.") }
        if let maxTokens, maxTokens <= 0 { throw .message("Max tokens must be positive.") }
    }

    @concurrent public func save(store: Store, keychain: Keychain = Keychain()) async throws {
        try validate()
        let row = try await store.modelConfig()
        try await store.saveModelConfig(provider: provider.rawValue, model: model.trimmingCharacters(in: .whitespaces),
                                        whisperModel: row?.whisperModel ?? "large-v3",
                                        ollamaEndpoint: ollamaEndpoint.isEmpty ? nil : ollamaEndpoint)
        if takesKey { try keychain.set(apiKey.trimmingCharacters(in: .whitespacesAndNewlines), for: provider.rawValue) }
        guard provider == .customOpenAI else { return }
        var json: [String: Any] = ["endpoint": customEndpoint, "model": model]
        json["maxTokens"] = maxTokens
        json["temperature"] = temperature
        json["topP"] = topP
        json["apiKey"] = Self.customJSON(row)["apiKey"] // left for the Tauri app until cutover (D10); ours is in the Keychain
        try await store.saveCustomOpenAIConfig(String(decoding: try JSONSerialization.data(withJSONObject: json, options: .sortedKeys), as: UTF8.self))
    }

    private static func customJSON(_ row: ModelConfig?) -> [String: Any] {
        row?.customOpenAIConfig.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] } ?? [:]
    }
}
