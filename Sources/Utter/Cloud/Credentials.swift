import Foundation
import Security

enum CloudService: String, CaseIterable, Identifiable, Sendable {
    case groq, openAI, anthropic
    var id: String { rawValue }
    var title: String {
        switch self { case .groq: "Groq"; case .openAI: "OpenAI"; case .anthropic: "Anthropic" }
    }
}
protocol CredentialStore: Sendable {
    func read(_ service: CloudService) throws -> String?
    func save(_ value: String, for service: CloudService) throws
    func delete(_ service: CloudService) throws
}
struct KeychainCredentialStore: CredentialStore {
    let namespace: String
    init(namespace: String = "org.utter.app.api-keys") { self.namespace = namespace }
    private func query(_ service: CloudService) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: namespace, kSecAttrAccount as String: service.rawValue]
    }
    func read(_ service: CloudService) throws -> String? {
        var request = query(service)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else { throw CloudError.keychain(status) }
        return value
    }
    func save(_ value: String, for service: CloudService) throws {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains("\n"), !value.contains("\r") else { throw CloudError.invalidKey }
        let data = Data(value.utf8)
        let status = SecItemUpdate(query(service) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query(service)
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw CloudError.keychain(added) }
        } else if status != errSecSuccess { throw CloudError.keychain(status) }
    }
    func delete(_ service: CloudService) throws {
        let status = SecItemDelete(query(service) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CloudError.keychain(status) }
    }
}

enum CloudError: LocalizedError {
    case disabled, missingKey(CloudService), invalidKey, keychain(OSStatus), http(Int), invalidResponse
    var errorDescription: String? {
        switch self {
        case .disabled: "Cloud access is off. Enable it in Transcription settings when you are ready."
        case .missingKey(let service): "Add your \(service.title) API key in Transcription settings."
        case .invalidKey: "Enter a nonempty API key without line breaks."
        case .keychain(let code): "Keychain could not complete the request (\(code))."
        case .http(401), .http(403): "The API key was rejected. Check the key and its account permissions."
        case .http(429): "The provider rate limit or account quota was reached. Try again later."
        case .http(let code): "The cloud provider returned HTTP \(code)."
        case .invalidResponse: "The cloud provider returned an invalid or empty response."
        }
    }
}
