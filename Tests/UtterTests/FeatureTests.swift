import XCTest
@testable import Utter

final class FeatureTests: XCTestCase {
    func testSnippetMatchesWholePhraseWithSentencePunctuation() {
        let options = TextTransformOptions(snippets: [Snippet(trigger: "my signature", expansion: "Thanks,\nMitch")])
        XCTAssertEqual(options.apply(to: "My signature."), "Thanks,\nMitch")
        XCTAssertEqual(options.apply(to: "Please add my signature"), "Please add my signature")
    }
    func testEmptyTriggerCannotExpandEverything() {
        XCTAssertEqual(TextTransformOptions(snippets: [Snippet(trigger: " ", expansion: "bad")]).apply(to: "hello"), "hello")
    }
    @MainActor func testFeaturesAreOffByDefaultAndPersist() throws {
        let suite = "UtterTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = FeatureSettings(defaults: defaults)
        XCTAssertFalse(settings.historyEnabled); XCTAssertFalse(settings.commandEnabled)
        XCTAssertFalse(settings.snippetsEnabled); XCTAssertFalse(settings.stylesEnabled)
        settings.dictionaryEnabled = true
        settings.dictionary = " Utter \nUTTER\n\nfetchUserByID"
        XCTAssertEqual(settings.terms, ["Utter", "fetchUserByID"])
        settings.stylesEnabled = true
        settings.styles = [AppStyleRule(bundleID: "com.apple.mail", style: .formal)]
        let restored = FeatureSettings(defaults: defaults)
        XCTAssertEqual(restored.terms, settings.terms)
        XCTAssertEqual(restored.style(for: "com.apple.mail"), .formal)
        XCTAssertEqual(restored.style(for: "com.apple.Notes"), .standard)
    }
    func testHistoryPersistsSearchesAndClears() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HistoryStore(directory: directory)
        let entry = HistoryEntry(id: "one", created: Date(), app: "Notes", bundleID: "com.apple.Notes",
                                 raw: "um hello world", cleaned: "Hello world.", path: "On-device")
        try await store.insert(entry, retentionDays: 7)
        let all = try await store.entries()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.raw, entry.raw)
        let second = HistoryStore(directory: directory)
        let found = try await second.entries(search: "HELLO")
        XCTAssertEqual(found.first?.id, "one")
        let injection = try await second.entries(search: "' OR 1=1 --")
        XCTAssertEqual(injection.count, 0)
        try await store.update(id: "one", cleaned: "Updated.")
        let updated = try await store.entries()
        XCTAssertEqual(updated.first?.cleaned, "Updated.")
        try await store.clear()
        let cleared = try await store.entries()
        XCTAssertTrue(cleared.isEmpty)
    }
    func testHistoryRetentionRemovesOldTranscripts() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HistoryStore(directory: directory)
        try await store.insert(.init(id: "old", created: Date().addingTimeInterval(-86_400 * 20), app: "Notes",
                                     bundleID: "notes", raw: "old", cleaned: "Old.", path: "Local"), retentionDays: 30)
        let entries = try await store.entries(retentionDays: 7)
        XCTAssertTrue(entries.isEmpty)
    }
    func testHistoryFilesHavePrivatePermissions() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HistoryStore(directory: directory)
        _ = try await store.entries()
        let permissions = try FileManager.default.attributesOfItem(atPath: directory.appending(path: "history.sqlite").path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }
}

@MainActor
private final class CommandInserter: TextInserter {
    var values: [String] = []
    var recovery: [String] = []
    func insert(_ text: String, target: InsertionTarget) async throws { values.append(text) }
    func copyForRecovery(_ text: String) throws { recovery.append(text) }
}
private struct TestEditor: CommandProvider {
    let fail: Bool
    func edit(selection: String, instruction: String, context: DictationContext) async throws -> String {
        if fail { throw CloudError.http(500) }
        return "Edited: \(selection)"
    }
}
final class CommandPipelineTests: XCTestCase {
    @MainActor func testCommandReplacesSelectionWithEditedText() async {
        let inserter = CommandInserter()
        let pipeline = DictationPipeline(inserter: inserter)
        pipeline.submit(audio: RecordedAudio(samples: [0.1]), context: .init(target: .init(processID: 1, appName: "Notes", bundleID: "notes")),
                        transcriber: SampleTextProvider(text: "make this formal"), path: .command,
                        selection: Task { "original selection" }, editor: TestEditor(fail: false))
        await pipeline.waitUntilIdle()
        XCTAssertEqual(inserter.values, ["Edited: original selection"])
    }
    @MainActor func testCommandFailureNeverPastesInstructionOverSelection() async {
        let inserter = CommandInserter()
        let pipeline = DictationPipeline(inserter: inserter)
        pipeline.submit(audio: RecordedAudio(samples: [0.1]), context: .init(target: .init(processID: 1, appName: "Notes", bundleID: "notes")),
                        transcriber: SampleTextProvider(text: "make this formal"), path: .command,
                        selection: Task { "original selection" }, editor: TestEditor(fail: true))
        await pipeline.waitUntilIdle()
        XCTAssertTrue(inserter.values.isEmpty)
        XCTAssertEqual(inserter.recovery, ["make this formal"])
    }
    @MainActor func testSnippetExpansionIsAppliedBeforeInsertionAndHistoryCallback() async {
        let inserter = CommandInserter()
        let pipeline = DictationPipeline(inserter: inserter)
        var recorded: String?
        pipeline.onResult = { _, text, _, _ in recorded = text }
        pipeline.submit(audio: RecordedAudio(samples: [0.1]), context: .init(target: .init(processID: 1, appName: "Notes", bundleID: "notes")),
                        transcriber: SampleTextProvider(text: "signature"),
                        transforms: TextTransformOptions(snippets: [Snippet(trigger: "signature", expansion: "Thanks, Mitch")]))
        await pipeline.waitUntilIdle()
        XCTAssertEqual(inserter.values, ["Thanks, Mitch"])
        XCTAssertEqual(recorded, "Thanks, Mitch")
    }
}
