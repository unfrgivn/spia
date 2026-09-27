import Foundation
import Security

/// API keys, stored in the user's Keychain.
public struct APIKeyStore: Sendable {
    public let service: String

    public init(service: String = "com.unfrgivn.spia.assistant") {
        self.service = service
    }

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case keychain(OSStatus)

        public var description: String {
            switch self {
            case .keychain(let status):
                let message =
                    SecCopyErrorMessageString(status, nil).map { String($0) } ?? "unknown error"
                return "Keychain error \(status): \(message)"
            }
        }
    }

    public func key(for provider: ProviderID) throws -> String? {
        var query = base(provider)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound:
            return nil
        default:
            throw Failure.keychain(status)
        }
    }

    /// Saves `key`, or removes the stored key when `key` is empty.
    public func setKey(_ key: String, for provider: ProviderID) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return try removeKey(for: provider) }
        let data = Data(trimmed.utf8)
        let update = SecItemUpdate(
            base(provider) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        switch update {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var item = base(provider)
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            let status = SecItemAdd(item as CFDictionary, nil)
            guard status == errSecSuccess else { throw Failure.keychain(status) }
        default:
            throw Failure.keychain(update)
        }
    }

    public func removeKey(for provider: ProviderID) throws {
        let status = SecItemDelete(base(provider) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Failure.keychain(status)
        }
    }

    private func base(_ provider: ProviderID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.rawValue,
        ]
    }
}

/// The user's assistant preferences. Keys live in the Keychain, not here.
public struct AssistantSettings: Codable, Sendable, Equatable {
    public var defaultProvider: ProviderID
    public var anthropicModel: String
    public var openAIModel: String
    /// Whether the VIN may be sent to cloud providers. Off by default.
    public var shareVIN: Bool

    public init(
        defaultProvider: ProviderID = .anthropic,
        anthropicModel: String = AnthropicProvider.defaultModel,
        openAIModel: String = OpenAIProvider.defaultModel, shareVIN: Bool = false
    ) {
        self.defaultProvider = defaultProvider
        self.anthropicModel = anthropicModel
        self.openAIModel = openAIModel
        self.shareVIN = shareVIN
    }

    static let defaultsKey = "assistant.settings"

    public static func load(from defaults: UserDefaults = .standard) -> AssistantSettings {
        guard let data = defaults.data(forKey: defaultsKey),
            let settings = try? JSONDecoder().decode(AssistantSettings.self, from: data)
        else { return AssistantSettings() }
        return settings
    }

    public func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }

    public func model(for provider: ProviderID) -> String {
        switch provider {
        case .onDevice: return "Apple on-device"
        case .anthropic: return anthropicModel
        case .openAI: return openAIModel
        }
    }

    /// A ready provider, or why it can't be used.
    public func provider(_ id: ProviderID, keys: APIKeyStore) throws -> any AssistantProvider {
        switch id {
        case .onDevice:
            if let reason = OnDeviceProvider.unavailableReason {
                throw AssistantError.unavailable(reason)
            }
            return OnDeviceProvider()
        case .anthropic:
            guard let key = try keys.key(for: .anthropic) else {
                throw AssistantError.missingAPIKey(.anthropic)
            }
            return AnthropicProvider(apiKey: key, model: anthropicModel)
        case .openAI:
            guard let key = try keys.key(for: .openAI) else {
                throw AssistantError.missingAPIKey(.openAI)
            }
            return OpenAIProvider(apiKey: key, model: openAIModel)
        }
    }
}
