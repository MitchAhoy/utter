import AppKit
import Combine

@MainActor
final class HistoryController: ObservableObject {
    @Published private(set) var entries: [HistoryEntry] = []
    @Published var search = "" { didSet { reload() } }
    @Published private(set) var message: String?
    @Published private(set) var busy = false
    private let store: HistoryStore
    private let settings: FeatureSettings
    private var searchTask: Task<Void, Never>?
    private var revision = 0
    init(settings: FeatureSettings, store: HistoryStore = HistoryStore()) { self.settings = settings; self.store = store }
    func record(raw: String, cleaned: String, context: DictationContext, path: DictationPath) {
        guard settings.historyEnabled else { return }
        let entry = HistoryEntry(id: UUID().uuidString, created: Date(), app: context.target.appName,
                                 bundleID: context.target.bundleID, raw: raw, cleaned: cleaned, path: path.title)
        let retention = settings.retentionDays
        Task {
            do { try await store.insert(entry, retentionDays: retention); reload() }
            catch { message = error.localizedDescription }
        }
    }
    func reload() {
        searchTask?.cancel()
        revision += 1
        let expected = revision
        let query = search
        let retention = settings.retentionDays
        searchTask = Task {
            do {
                let result = try await store.entries(search: query, retentionDays: retention)
                guard !Task.isCancelled, expected == revision else { return }
                entries = result
            } catch { if !Task.isCancelled { message = error.localizedDescription } }
        }
    }
    func clear() {
        Task {
            do { try await store.clear(); entries = []; message = "History cleared." }
            catch { message = error.localizedDescription }
        }
    }
    func copy(_ entry: HistoryEntry) {
        let clipboard = SystemPasteboard()
        do { _ = try clipboard.writeText(entry.cleaned, transient: false, rollback: nil); message = "Copied to clipboard." }
        catch { message = error.localizedDescription }
    }
    func rerun(_ entry: HistoryEntry, cleaner: any CleanupProvider) {
        guard !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                let context = DictationContext(target: .init(processID: 0, appName: entry.app, bundleID: entry.bundleID),
                                               dictionary: settings.terms, style: settings.style(for: entry.bundleID))
                let timeout = Duration.seconds(10)
                let result = try await withStageTimeout(timeout) { try await cleaner.clean(raw: entry.raw, context: context) }
                try await store.update(id: entry.id, cleaned: result)
                reload(); message = "Cleanup updated in history. Copy it when ready."
            } catch { message = error.localizedDescription }
        }
    }
}
