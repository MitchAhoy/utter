import Foundation
import Combine

/// Which service rewrites transcripts and runs spoken edits.
enum CleanupService: String, CaseIterable, Identifiable, Sendable {
    case groq, anthropic
    var id: String { rawValue }
    var credential: CloudService { self == .groq ? .groq : .anthropic }
    var title: String { self == .groq ? "Groq (fastest)" : "Anthropic Claude" }
    var host: String { self == .groq ? "api.groq.com" : "api.anthropic.com" }
}

@MainActor
final class CloudSettings: ObservableObject {
    private let defaults: UserDefaults
    private let credentials: any CredentialStore
    @Published var enabled: Bool { didSet { defaults.set(enabled, forKey: "cloudEnabled"); if !enabled { onDisabled?() } } }
    @Published var provider: CloudTranscriber { didSet { defaults.set(provider.rawValue, forKey: "cloudProvider") } }
    @Published var cleanupEnabled: Bool { didSet { defaults.set(cleanupEnabled, forKey: "cleanupEnabled") } }
    @Published var cleanupTimeout: Double { didSet { defaults.set(cleanupTimeout, forKey: "cleanupTimeout") } }
    @Published var cleanupService: CleanupService { didSet { defaults.set(cleanupService.rawValue, forKey: "cleanupService") } }
    /// Claude model identifier.
    @Published var cleanupModel: String { didSet { defaults.set(cleanupModel, forKey: "cleanupModel") } }
    @Published var groqCleanupModel: String { didSet { defaults.set(groqCleanupModel, forKey: "groqCleanupModel") } }
    /// Sends the text just before the cursor to cleanup so it can continue sentences naturally.
    @Published var cleanupUsesContext: Bool { didSet { defaults.set(cleanupUsesContext, forKey: "cleanupUsesContext") } }
    @Published private(set) var storedKeys: Set<CloudService> = []
    @Published private(set) var message: String?
    /// Keys already read this launch, so the key file is read at most once per key.
    private var cachedKeys: [CloudService: String] = [:]
    var onDisabled: (@MainActor () -> Void)?
    init(defaults: UserDefaults = .standard, credentials: any CredentialStore = MigratingCredentialStore.standard) {
        self.defaults = defaults; self.credentials = credentials
        enabled = defaults.bool(forKey: "cloudEnabled")
        provider = CloudTranscriber(rawValue: defaults.string(forKey: "cloudProvider") ?? "") ?? .groq
        cleanupEnabled = defaults.bool(forKey: "cleanupEnabled")
        cleanupTimeout = defaults.object(forKey: "cleanupTimeout") as? Double ?? 1.5
        cleanupService = CleanupService(rawValue: defaults.string(forKey: "cleanupService") ?? "") ?? .groq
        cleanupModel = defaults.string(forKey: "cleanupModel") ?? "claude-haiku-5-5"
        groqCleanupModel = defaults.string(forKey: "groqCleanupModel") ?? GroqCleanupProvider.defaultModel
        cleanupUsesContext = defaults.object(forKey: "cleanupUsesContext") as? Bool ?? true
    }
    /// Cloud on and the selected cleanup service has a key.
    var cleanupAvailable: Bool { enabled && storedKeys.contains(cleanupService.credential) }
    var cleanupActive: Bool { cleanupEnabled && cleanupAvailable }
    func refreshKeys() {
        do {
            var found = Set<CloudService>()
            for service in CloudService.allCases {
                if try credentials.exists(service) { found.insert(service) } else { cachedKeys[service] = nil }
            }
            storedKeys = found
        } catch { message = error.localizedDescription }
    }
    @discardableResult
    func save(_ value: String, service: CloudService) -> Bool {
        do {
            try credentials.save(value, for: service)
            cachedKeys[service] = value.trimmingCharacters(in: .whitespacesAndNewlines)
            refreshKeys(); message = "\(service.title) key saved."; return true }
        catch { message = error.localizedDescription; return false }
    }
    func delete(_ service: CloudService) {
        do { try credentials.delete(service); cachedKeys[service] = nil; refreshKeys(); message = "\(service.title) key removed." }
        catch { message = error.localizedDescription }
    }
    private func authorizedKey(_ service: CloudService) throws -> String {
        guard enabled else { throw CloudError.disabled }
        if let cached = cachedKeys[service] { return cached }
        guard let value = try credentials.read(service), !value.isEmpty else { throw CloudError.missingKey(service) }
        cachedKeys[service] = value
        return value
    }
    /// Reads the keys this setup will use at launch. A one-time move from older Keychain storage
    /// can ask for the password once; that happens now instead of in the middle of a dictation.
    func preloadKeys() {
        guard enabled else { return }
        var needed: Set<CloudService> = [provider.service]
        if cleanupEnabled { needed.insert(cleanupService.credential) }
        for service in needed where storedKeys.contains(service) { _ = try? authorizedKey(service) }
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
        return editor()
    }
    /// Provider for cleanup and spoken edits, using the selected service.
    func editor(timeout: TimeInterval? = nil) -> any CleanupProvider & CommandProvider {
        switch cleanupService {
        case .groq:
            let model = groqCleanupModel.trimmingCharacters(in: .whitespacesAndNewlines)
            return GroqCleanupProvider(model: model.isEmpty ? GroqCleanupProvider.defaultModel : model,
                                       timeout: timeout ?? cleanupTimeout, authorize: authorization(.groq))
        case .anthropic:
            return claude(timeout: timeout)
        }
    }
    func claude(timeout: TimeInterval? = nil) -> ClaudeCleanupProvider {
        ClaudeCleanupProvider(model: cleanupModel.trimmingCharacters(in: .whitespacesAndNewlines),
                              timeout: timeout ?? cleanupTimeout, authorize: authorization(.anthropic))
    }
    /// Pre-opens connections to the services this dictation will call.
    func warmConnections(transcription: Bool, cleanup: Bool) {
        guard enabled else { return }
        var hosts = Set<String>()
        if transcription, storedKeys.contains(provider.service), let host = provider.endpoint.host { hosts.insert(host) }
        if cleanup, cleanupActive { hosts.insert(cleanupService.host) }
        for host in hosts { URLSessionCloudTransport.shared.warm(host: host) }
    }
}
