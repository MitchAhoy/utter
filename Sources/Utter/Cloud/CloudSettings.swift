import Foundation
import Combine

@MainActor
final class CloudSettings: ObservableObject {
    private let defaults: UserDefaults
    private let credentials: any CredentialStore
    @Published var enabled: Bool { didSet { defaults.set(enabled, forKey: "cloudEnabled"); if !enabled { onDisabled?() } } }
    @Published var provider: CloudTranscriber { didSet { defaults.set(provider.rawValue, forKey: "cloudProvider") } }
    @Published var cleanupEnabled: Bool { didSet { defaults.set(cleanupEnabled, forKey: "cleanupEnabled") } }
    @Published var cleanupTimeout: Double { didSet { defaults.set(cleanupTimeout, forKey: "cleanupTimeout") } }
    @Published var cleanupModel: String { didSet { defaults.set(cleanupModel, forKey: "cleanupModel") } }
    @Published private(set) var storedKeys: Set<CloudService> = []
    @Published private(set) var message: String?
    var onDisabled: (@MainActor () -> Void)?
    init(defaults: UserDefaults = .standard, credentials: any CredentialStore = KeychainCredentialStore()) {
        self.defaults = defaults; self.credentials = credentials
        enabled = defaults.bool(forKey: "cloudEnabled")
        provider = CloudTranscriber(rawValue: defaults.string(forKey: "cloudProvider") ?? "") ?? .groq
        cleanupEnabled = defaults.bool(forKey: "cleanupEnabled")
        cleanupTimeout = defaults.object(forKey: "cleanupTimeout") as? Double ?? 1.5
        cleanupModel = defaults.string(forKey: "cleanupModel") ?? "claude-haiku-5-5"
    }
    func refreshKeys() {
        do {
            var found = Set<CloudService>()
            for service in CloudService.allCases {
                if let value = try credentials.read(service), !value.isEmpty { found.insert(service) }
            }
            storedKeys = found
        } catch { message = error.localizedDescription }
    }
    @discardableResult
    func save(_ value: String, service: CloudService) -> Bool {
        do { try credentials.save(value, for: service); refreshKeys(); message = "\(service.title) key saved to Keychain."; return true }
        catch { message = error.localizedDescription; return false }
    }
    func delete(_ service: CloudService) {
        do { try credentials.delete(service); refreshKeys(); message = "\(service.title) key removed." }
        catch { message = error.localizedDescription }
    }
    private func authorizedKey(_ service: CloudService) throws -> String {
        guard enabled else { throw CloudError.disabled }
        guard let value = try credentials.read(service), !value.isEmpty else { throw CloudError.missingKey(service) }
        return value
    }
    func authorization(_ service: CloudService) -> @Sendable () async throws -> String {
        { [weak self] in
            guard let self else { throw CloudError.disabled }
            return try await self.authorizedKey(service)
        }
    }
    func transcriber() -> any TranscriptionProvider {
        CloudTranscriptionProvider(provider: provider, authorize: authorization(provider.service))
    }
    func cleaner() -> any CleanupProvider {
        guard cleanupEnabled, enabled else { return PassthroughProvider() }
        return claude()
    }
    func claude(timeout: TimeInterval? = nil) -> ClaudeCleanupProvider {
        ClaudeCleanupProvider(model: cleanupModel.trimmingCharacters(in: .whitespacesAndNewlines),
                              timeout: timeout ?? cleanupTimeout, authorize: authorization(.anthropic))
    }
}
