import Foundation
import Combine

enum LocalModelState: Equatable {
    case notInstalled, preparing(Double?, String), ready, failed(String)
    var isPreparing: Bool { if case .preparing = self { return true }; return false }
}

@MainActor
final class LocalModelController: ObservableObject {
    @Published private(set) var selectedModel: LocalModel
    @Published private(set) var state: LocalModelState = .notInstalled
    private let engine: any LocalSpeechEngine
    private let defaults: UserDefaults
    private var preparation: Task<Void, Never>?
    private var operation = UUID()
    var onReady: (@MainActor () -> Void)?
    var isReady: Bool { state == .ready }
    var provider: any TranscriptionProvider { engine }

    init(engine: any LocalSpeechEngine = WhisperKitProvider(), defaults: UserDefaults = .standard) {
        self.engine = engine
        self.defaults = defaults
        selectedModel = LocalModel(rawValue: defaults.string(forKey: "localModel") ?? "") ?? .largeTurbo
    }

    func select(_ model: LocalModel) {
        guard !state.isPreparing, model != selectedModel else { return }
        selectedModel = model
        defaults.set(model.rawValue, forKey: "localModel")
        prepare(download: false)
    }

    func prepare(download: Bool) {
        guard preparation == nil else { return }
        let model = selectedModel
        let id = UUID()
        operation = id
        state = .preparing(nil, "Checking local model…")
        preparation = Task { [weak self, engine] in
            do {
                if !download, !(await engine.isInstalled(model)) {
                    guard let self, self.operation == id else { return }
                    self.state = .notInstalled
                    self.preparation = nil
                    return
                }
                try Task.checkCancellation()
                try await engine.prepare(model, allowDownload: download) { [weak self] fraction, message in
                    Task { @MainActor [weak self] in
                        guard let self, self.operation == id, self.preparation != nil else { return }
                        self.state = .preparing(fraction, message)
                    }
                }
                try Task.checkCancellation()
                guard let self, self.operation == id else { return }
                self.state = .ready
                self.preparation = nil
                self.onReady?()
            } catch {
                guard let self, self.operation == id else { return }
                self.state = Task.isCancelled ? .notInstalled : .failed(error.localizedDescription)
                self.preparation = nil
            }
        }
    }

    func cancel() { preparation?.cancel() }
    func waitUntilSettled() async { await preparation?.value }
}
