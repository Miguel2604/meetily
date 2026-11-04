import Foundation
import Security

public enum KeychainError: Error, Equatable { case status(OSStatus) }

/// Provider API keys in the login keychain (D10), one generic password per provider id.
public struct Keychain: Sendable {
    public let service: String
    public init(service: String = Keychain.defaultService) { self.service = service }

    /// Dev runs on a copy of the data (`MEETY_DATA_DIR`) keep their keys apart from the real ones.
    /// Snapshot runs (`MEETY_SNAPSHOT`) read an empty service: each Debug build re-signs ad hoc, so reading saved keys would prompt.
    public static var defaultService: String {
        let env = ProcessInfo.processInfo.environment
        if env["MEETY_SNAPSHOT"] != nil { return "com.meetily.ai.snapshot.api-keys" }
        return env["MEETY_DATA_DIR"].map { $0.isEmpty ? "com.meetily.ai.api-keys" : "com.meetily.ai.dev.api-keys" }
            ?? "com.meetily.ai.api-keys"
    }

    public static let providers = ["openai", "claude", "groq", "openrouter", "ollama", "custom-openai"]

    public func get(_ provider: String) -> String? {
        var query = base(provider)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Stores the key, or deletes it when `value` is nil or empty.
    public func set(_ value: String?, for provider: String) throws {
        let query = base(provider)
        guard let value, !value.isEmpty else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError.status(status) }
            return
        }
        let data = Data(value.utf8)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError.status(status) }
    }

    /// Copies keys from the `settings` row into the keychain, skipping providers that already have one.
    /// The plaintext columns are left untouched (D10). TODO(cutover): clear them; the SQL is in README.md. Returns how many keys were copied.
    /// Off the main actor: a keychain read can block on an access prompt.
    @concurrent public func importKeys(from store: Store) async throws -> Int {
        guard let row = try await store.modelConfig() else { return 0 }
        let customKey = row.customOpenAIConfig
            .flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }?["apiKey"] as? String
        let columns: [(String, String?)] = [
            ("openai", row.openaiApiKey), ("claude", row.anthropicApiKey), ("groq", row.groqApiKey),
            ("openrouter", row.openRouterApiKey), ("ollama", row.ollamaApiKey), ("custom-openai", customKey),
        ]
        var copied = 0
        for case let (provider, key?) in columns where !key.isEmpty && get(provider) == nil {
            try set(key, for: provider)
            copied += 1
        }
        return copied
    }

    private func base(_ provider: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: provider]
    }
}
