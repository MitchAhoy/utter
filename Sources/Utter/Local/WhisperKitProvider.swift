import Foundation
@preconcurrency import WhisperKit

/// Actor owns the warm Core ML pipeline. No network path is entered by transcribe().
actor WhisperKitProvider: LocalSpeechEngine {
    private let store: LocalModelStore
    private var kit: WhisperKit?
    private var loadedModel: LocalModel?
    private var busy = false

    init(store: LocalModelStore = LocalModelStore()) { self.store = store }
    func isInstalled(_ model: LocalModel) -> Bool { store.isInstalled(model) }

    func prepare(_ model: LocalModel, allowDownload: Bool,
                 progress: @escaping @Sendable (Double?, String) -> Void) async throws {
        guard !busy else { throw LocalModelError.busy }
        if loadedModel == model, kit != nil { return }
        busy = true
        var prepared = false
        defer {
            busy = false
            if !prepared, !Task.isCancelled { try? store.invalidateReceipt(model) }
        }
        Logging.updateLogLevel(.none)
        if !store.isInstalled(model) {
            guard allowDownload else { throw LocalModelError.notInstalled }
            try FileManager.default.createDirectory(at: store.root, withIntermediateDirectories: true)
            progress(0, "Downloading \(model.title)…")
            _ = try await WhisperKit.download(variant: model.remoteName, downloadBase: store.root, token: "") { value in
                progress(min(0.9, value.fractionCompleted * 0.9), "Downloading \(model.title)…")
            }
            try Task.checkCancellation()
            progress(0.9, "Downloading language files…")
            let hub = HubApiWrapper(downloadBase: store.root, hfToken: "")
            _ = try await hub.snapshot(from: .init(id: model.tokenizerRepo),
                                      matching: ["tokenizer.json", "tokenizer_config.json", "config.json"])
        }
        try Task.checkCancellation()
        guard store.filesExist(model) else { throw LocalModelError.invalidFiles }
        progress(nil, "Preparing \(model.title) for this Mac…")
        // Parse local tokenizer directly. WhisperKit's automatic tokenizer loader can
        // fall back to a network download; injecting a local tokenizer avoids that path.
        let tokenizer = try await AutoTokenizerWrapper.from(modelFolder: store.tokenizerFolder(model))
        try Task.checkCancellation()
        let next = try await WhisperKit(WhisperKitConfig(
            modelFolder: store.modelFolder(model).path,
            tokenizerFolder: store.tokenizerFolder(model),
            verbose: false, prewarm: false, load: false, download: false
        ))
        next.tokenizer = try OfflineWhisperTokenizer(tokenizer)
        try await next.loadModels()
        // Both offered models are multilingual. With a tokenizer injected up front,
        // WhisperKit skips its automatic model-language detection.
        next.textDecoder.isModelMultilingual = true
        try Task.checkCancellation()
        try store.markInstalled(model)
        kit = next
        loadedModel = model
        prepared = true
        progress(1, "Ready · \(model.title)")
    }

    func transcribe(audio: RecordedAudio, language: String?, prompt: String?) async throws -> String {
        guard !busy else { throw LocalModelError.busy }
        guard let kit else { throw LocalModelError.notInstalled }
        guard !audio.samples.isEmpty else { throw LocalModelError.noSpeech }
        // Avoid hallucinating text for silence. This threshold is deliberately low.
        let energy = audio.samples.reduce(Double(0)) { $0 + Double($1) * Double($1) } / Double(audio.samples.count)
        guard energy.isFinite, energy > 0.00000001 else { throw LocalModelError.noSpeech }
        busy = true
        defer { busy = false }
        try Task.checkCancellation()
        let tokens = prompt.flatMap { kit.tokenizer?.encode(text: $0) }
        let options = DecodingOptions(
            verbose: false, language: language,
            temperatureFallbackCount: 2, detectLanguage: language == nil,
            skipSpecialTokens: true, withoutTimestamps: true,
            promptTokens: tokens, concurrentWorkerCount: 1, chunkingStrategy: .vad
        )
        let result = try await kit.transcribe(audioArray: audio.samples, decodeOptions: options) { _ in
            !Task.isCancelled
        }
        try Task.checkCancellation()
        let text = result.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw LocalModelError.noSpeech }
        return text
    }
}
