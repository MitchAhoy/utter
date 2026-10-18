import XCTest
@testable import Utter

private actor FakeLocalEngine: LocalSpeechEngine {
    private var installed: Set<LocalModel>
    private var failing = false
    private var delay: Duration = .zero
    private var preparations = 0
    init(installed: Set<LocalModel> = []) { self.installed = installed }
    func configure(failing: Bool = false, delay: Duration = .zero) { self.failing = failing; self.delay = delay }
    func count() -> Int { preparations }
    func isInstalled(_ model: LocalModel) -> Bool { installed.contains(model) }
    func prepare(_ model: LocalModel, allowDownload: Bool, progress: @escaping @Sendable (Double?, String) -> Void) async throws {
        preparations += 1
        guard allowDownload || installed.contains(model) else { throw LocalModelError.notInstalled }
        progress(0.5, "Preparing")
        try await Task.sleep(for: delay)
        if failing { throw LocalModelError.invalidFiles }
        try Task.checkCancellation()
        installed.insert(model)
    }
    func transcribe(audio: RecordedAudio, language: String?, prompt: String?) async throws -> String { "fixture" }
}

final class LocalModelTests: XCTestCase {
    private func temporaryStore() -> LocalModelStore {
        LocalModelStore(root: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
    }
    private func addPlaceholders(_ model: LocalModel, store: LocalModelStore) throws {
        for component in ["MelSpectrogram", "AudioEncoder", "TextDecoder"] {
            try FileManager.default.createDirectory(at: store.modelFolder(model).appending(path: "\(component).mlmodelc"), withIntermediateDirectories: true)
        }
        try FileManager.default.createDirectory(at: store.tokenizerFolder(model), withIntermediateDirectories: true)
        for name in ["tokenizer.json", "tokenizer_config.json"] {
            try Data("{}".utf8).write(to: store.tokenizerFolder(model).appending(path: name))
        }
    }
    func testPartialDownloadIsNotAnInstallation() throws {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        try addPlaceholders(.small, store: store)
        XCTAssertFalse(store.isInstalled(.small))
        try store.markInstalled(.small)
        XCTAssertTrue(store.isInstalled(.small))
        XCTAssertFalse(store.isInstalled(.largeTurbo))
    }
    func testInvalidatingReceiptRetainsReusableModelFiles() throws {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        try addPlaceholders(.small, store: store)
        try store.markInstalled(.small)
        try store.invalidateReceipt(.small)
        XCTAssertFalse(store.isInstalled(.small))
        XCTAssertTrue(store.filesExist(.small))
    }
    func testMissingTokenizerInvalidatesInstalledReceipt() throws {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        try addPlaceholders(.small, store: store)
        try store.markInstalled(.small)
        try FileManager.default.removeItem(at: store.tokenizerFolder(.small).appending(path: "tokenizer.json"))
        XCTAssertFalse(store.isInstalled(.small))
    }
    func testCannotMarkIncompleteModelInstalled() throws {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        XCTAssertThrowsError(try store.markInstalled(.small))
    }
    func testUnknownReceiptVersionIsRejected() throws {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        try addPlaceholders(.small, store: store)
        try Data(#"{"version":999,"model":"small"}"#.utf8).write(to: store.root.appending(path: "installed-small.json"))
        XCTAssertFalse(store.isInstalled(.small))
    }
    func testProviderDoesNotDownloadWhenNotAllowed() async throws {
        let store = temporaryStore()
        let engine = WhisperKitProvider(store: store)
        do {
            try await engine.prepare(.small, allowDownload: false) { _, _ in XCTFail("Should not start a download") }
            XCTFail("Expected missing model error")
        } catch LocalModelError.notInstalled { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.root.path))
    }
    func testProviderRejectsDictationBeforePreparation() async throws {
        let engine = WhisperKitProvider(store: temporaryStore())
        do {
            _ = try await engine.transcribe(audio: RecordedAudio(samples: [0.1]), language: "en", prompt: nil)
            XCTFail("Expected missing model error")
        } catch LocalModelError.notInstalled { }
    }

    @MainActor private func defaults(_ id: String) -> UserDefaults {
        let defaults = UserDefaults(suiteName: id)!
        defaults.removePersistentDomain(forName: id)
        return defaults
    }
    @MainActor func testColdStartupDoesNotDownloadAModel() async {
        let id = "UtterTests-\(UUID().uuidString)"
        let defaults = defaults(id)
        defer { defaults.removePersistentDomain(forName: id) }
        let engine = FakeLocalEngine()
        let controller = LocalModelController(engine: engine, defaults: defaults)
        controller.prepare(download: false)
        await controller.waitUntilSettled()
        XCTAssertEqual(controller.selectedModel, .largeTurbo)
        XCTAssertEqual(controller.state, .notInstalled)
        let count = await engine.count()
        XCTAssertEqual(count, 0)
    }
    @MainActor func testCachedModelWarmsWithoutDownloading() async {
        let id = "UtterTests-\(UUID().uuidString)"
        let defaults = defaults(id)
        defer { defaults.removePersistentDomain(forName: id) }
        defaults.set(LocalModel.small.rawValue, forKey: "localModel")
        let controller = LocalModelController(engine: FakeLocalEngine(installed: [.small]), defaults: defaults)
        controller.prepare(download: false)
        await controller.waitUntilSettled()
        XCTAssertEqual(controller.state, .ready)
    }
    @MainActor func testExplicitDownloadBecomesReadyAndPersistsSelection() async {
        let id = "UtterTests-\(UUID().uuidString)"
        let defaults = defaults(id)
        defer { defaults.removePersistentDomain(forName: id) }
        let controller = LocalModelController(engine: FakeLocalEngine(), defaults: defaults)
        controller.select(.small)
        await controller.waitUntilSettled()
        controller.prepare(download: true)
        await controller.waitUntilSettled()
        XCTAssertTrue(controller.isReady)
        let second = LocalModelController(engine: FakeLocalEngine(), defaults: defaults)
        XCTAssertEqual(second.selectedModel, .small)
    }
    @MainActor func testFailedPreparationCanBeRetried() async {
        let id = "UtterTests-\(UUID().uuidString)"
        let defaults = defaults(id)
        defer { defaults.removePersistentDomain(forName: id) }
        let engine = FakeLocalEngine()
        await engine.configure(failing: true)
        let controller = LocalModelController(engine: engine, defaults: defaults)
        controller.prepare(download: true)
        await controller.waitUntilSettled()
        if case .failed = controller.state { } else { XCTFail("Expected visible error") }
        await engine.configure()
        controller.prepare(download: true)
        await controller.waitUntilSettled()
        XCTAssertTrue(controller.isReady)
    }
    @MainActor func testCancelPreparationAllowsRetry() async {
        let id = "UtterTests-\(UUID().uuidString)"
        let defaults = defaults(id)
        defer { defaults.removePersistentDomain(forName: id) }
        let engine = FakeLocalEngine()
        await engine.configure(delay: .seconds(60))
        let controller = LocalModelController(engine: engine, defaults: defaults)
        controller.prepare(download: true)
        controller.cancel()
        await controller.waitUntilSettled()
        XCTAssertEqual(controller.state, .notInstalled)
        await engine.configure()
        controller.prepare(download: true)
        await controller.waitUntilSettled()
        XCTAssertTrue(controller.isReady)
    }
    @MainActor func testSelectionCannotChangeDuringPreparation() async {
        let id = "UtterTests-\(UUID().uuidString)"
        let defaults = defaults(id)
        defer { defaults.removePersistentDomain(forName: id) }
        let controller = LocalModelController(engine: FakeLocalEngine(), defaults: defaults)
        controller.prepare(download: true)
        controller.select(.small)
        XCTAssertEqual(controller.selectedModel, .largeTurbo)
        await controller.waitUntilSettled()
    }
}
