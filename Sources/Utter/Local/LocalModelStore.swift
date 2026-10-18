import Foundation

/// Stores only model metadata. No audio, transcripts, or credentials are persisted.
struct LocalModelStore: Sendable {
    let root: URL
    init(root: URL = URL.applicationSupportDirectory.appending(path: "Utter/Models", directoryHint: .isDirectory)) {
        self.root = root
    }
    private struct Receipt: Codable {
        let version: Int
        let model: LocalModel
    }
    func modelFolder(_ model: LocalModel) -> URL {
        root.appending(path: "models/argmaxinc/whisperkit-coreml/\(model.remoteName)", directoryHint: .isDirectory)
    }
    func tokenizerFolder(_ model: LocalModel) -> URL {
        root.appending(path: "models/\(model.tokenizerRepo)", directoryHint: .isDirectory)
    }
    private func receiptURL(_ model: LocalModel) -> URL { root.appending(path: "installed-\(model.rawValue).json") }

    func filesExist(_ model: LocalModel) -> Bool {
        let files = FileManager.default
        let modelPath = modelFolder(model)
        let components = ["MelSpectrogram", "AudioEncoder", "TextDecoder"]
        let modelsExist = components.allSatisfy { name in
            ["mlmodelc", "mlpackage"].contains { ext in
                files.fileExists(atPath: modelPath.appending(path: "\(name).\(ext)").path)
            }
        }
        let tokenizerPath = tokenizerFolder(model)
        return modelsExist && ["tokenizer.json", "tokenizer_config.json"].allSatisfy {
            files.fileExists(atPath: tokenizerPath.appending(path: $0).path)
        }
    }

    func isInstalled(_ model: LocalModel) -> Bool {
        guard let data = try? Data(contentsOf: receiptURL(model)),
              let receipt = try? JSONDecoder().decode(Receipt.self, from: data),
              receipt.version == 1, receipt.model == model else { return false }
        return filesExist(model)
    }

    func invalidateReceipt(_ model: LocalModel) throws {
        let url = receiptURL(model)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    func markInstalled(_ model: LocalModel) throws {
        guard filesExist(model) else { throw LocalModelError.invalidFiles }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(Receipt(version: 1, model: model))
        try data.write(to: receiptURL(model), options: .atomic)
    }
}
