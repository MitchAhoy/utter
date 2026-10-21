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
    /// Whether a key is saved, without reading (and unlocking) the secret itself.
    func exists(_ service: CloudService) throws -> Bool
}
extension CredentialStore {
    func exists(_ service: CloudService) throws -> Bool { (try read(service)).map { !$0.isEmpty } ?? false }
}
/// Keys in a JSON file readable only by this Mac account (Credentials folder 0700, file 0600).
/// Chosen over Keychain because a locally built app gets a new identity on every build,
/// and macOS then asks for the login password again.
struct FileCredentialStore: CredentialStore {
    static let standardURL: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Utter/Credentials", isDirectory: true).appendingPathComponent("api-keys.json")
    private static let lock = NSLock()
    let url: URL
    init(url: URL = FileCredentialStore.standardURL) { self.url = url }

    func read(_ service: CloudService) throws -> String? {
        try Self.lock.withLock { try load()[service.rawValue] }
    }
    func exists(_ service: CloudService) throws -> Bool { (try read(service)).map { !$0.isEmpty } ?? false }
    func save(_ value: String, for service: CloudService) throws {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains("\n"), !value.contains("\r") else { throw CloudError.invalidKey }
        try Self.lock.withLock {
            var keys = try load()
            keys[service.rawValue] = value
            try write(keys)
        }
    }
    func delete(_ service: CloudService) throws {
        try Self.lock.withLock {
            var keys = try load()
            guard keys.removeValue(forKey: service.rawValue) != nil else { return }
            try write(keys)
        }
    }
    private func load() throws -> [String: String] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        do { return try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url)) }
        catch { throw CloudError.credentialFile }
    }
    private func write(_ keys: [String: String]) throws {
        let manager = FileManager.default
        let folder = url.deletingLastPathComponent()
        do {
            try manager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
            if keys.isEmpty {
                if manager.fileExists(atPath: url.path) { try manager.removeItem(at: url) }
                return
            }
            let data = try JSONEncoder().encode(keys)
            // Created with owner-only permissions from the start, then swapped in atomically.
            let temporary = folder.appendingPathComponent(".api-keys-\(UUID().uuidString).tmp")
            guard manager.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
                throw CloudError.credentialFile
            }
            guard Foundation.rename(temporary.path, url.path) == 0 else {
                try? manager.removeItem(at: temporary)
                throw CloudError.credentialFile
            }
        } catch let error as CloudError { throw error } catch { throw CloudError.credentialFile }
    }
}

/// Uses the key file, moving any key saved by earlier versions out of Keychain the first time it is needed.
struct MigratingCredentialStore: CredentialStore {
    let primary: any CredentialStore
    let legacy: any CredentialStore
    static var standard: MigratingCredentialStore {
        MigratingCredentialStore(primary: FileCredentialStore(), legacy: KeychainCredentialStore())
    }
    func read(_ service: CloudService) throws -> String? {
        if let value = try primary.read(service), !value.isEmpty { return value }
        guard (try? legacy.exists(service)) == true, let value = try legacy.read(service), !value.isEmpty else { return nil }
        try primary.save(value, for: service)
        try? legacy.delete(service)
        return value
    }
    func exists(_ service: CloudService) throws -> Bool {
        if try primary.exists(service) { return true }
        return (try? legacy.exists(service)) ?? false
    }
    func save(_ value: String, for service: CloudService) throws {
        try primary.save(value, for: service)
        if (try? legacy.exists(service)) == true { try? legacy.delete(service) }
    }
    func delete(_ service: CloudService) throws {
        try primary.delete(service)
        if (try? legacy.exists(service)) == true { try? legacy.delete(service) }
    }
}

/// Earlier versions stored keys here; now read only to migrate them.
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
    /// Asks only for attributes, which macOS returns without a Keychain password prompt.
    func exists(_ service: CloudService) throws -> Bool {
        var request = query(service)
        request[kSecReturnAttributes as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return false }
        guard status == errSecSuccess else { throw CloudError.keychain(status) }
        return true
    }
    func delete(_ service: CloudService) throws {
        let status = SecItemDelete(query(service) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CloudError.keychain(status) }
    }
}

enum CloudError: LocalizedError {
    case disabled, missingKey(CloudService), invalidKey, keychain(OSStatus), credentialFile, http(Int), invalidResponse
    var errorDescription: String? {
        switch self {
        case .disabled: "Cloud access is off. Enable it in Transcription settings when you are ready."
        case .missingKey(let service): "Add your \(service.title) API key in Transcription settings."
        case .invalidKey: "Enter a nonempty API key without line breaks."
        case .keychain(let code): "Keychain could not complete the request (\(code))."
        case .credentialFile: "The API key file in Application Support/Utter Credentials could not be read or saved."
        case .http(401), .http(403): "The API key was rejected. Check the key and its account permissions."
        case .http(429): "The provider rate limit or account quota was reached. Try again later."
        case .http(let code): "The cloud provider returned HTTP \(code)."
        case .invalidResponse: "The cloud provider returned an invalid or empty response."
        }
    }
}
