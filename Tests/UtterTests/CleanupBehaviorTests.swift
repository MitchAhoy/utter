import XCTest
@testable import Utter

@MainActor
private final class RecordingInserter: TextInserter {
    var inserted: [String] = []
    func insert(_ text: String, target: InsertionTarget) async throws { inserted.append(text) }
    func copyForRecovery(_ text: String) throws {}
}

private struct FixedCleanup: CleanupProvider {
    let output: String
    func clean(raw: String, context: DictationContext) async throws -> String { output }
}

private struct NamedCleanup: CleanupProvider {
    let output: String?
    var serviceName: String? { "Groq" }
    func clean(raw: String, context: DictationContext) async throws -> String {
        guard let output else { throw CloudError.http(401) }
        return output
    }
}

private actor ContextCapture: CleanupProvider {
    private(set) var seen: DictationContext?
    nonisolated func clean(raw: String, context: DictationContext) async throws -> String {
        await store(context)
        return raw
    }
    private func store(_ context: DictationContext) { seen = context }
}

final class CleanupBehaviorTests: XCTestCase {
    private let audio = RecordedAudio(samples: [0, 0.1])
    private let context = DictationContext(target: InsertionTarget(processID: 42, appName: "Notes", bundleID: "com.apple.Notes"))

    func testSpacingAfterExistingText() {
        XCTAssertEqual(InsertionSpacing.adjust("Hello there.", after: "Done."), " Hello there.")
        XCTAssertEqual(InsertionSpacing.adjust("Hello there.", after: "Done. "), "Hello there.")
        XCTAssertEqual(InsertionSpacing.adjust("Hello there.", after: ""), "Hello there.")
        XCTAssertEqual(InsertionSpacing.adjust("Hello there.", after: nil), "Hello there.")
        XCTAssertEqual(InsertionSpacing.adjust(", and more", after: "word"), ", and more")
        XCTAssertEqual(InsertionSpacing.adjust("quoted", after: "\""), "quoted")
        XCTAssertEqual(InsertionSpacing.adjust("  padded  ", after: "x\n"), "padded")
    }

    func testPlausibilityRejectsAnswers() {
        let raw = "what's the capital of France"
        XCTAssertTrue(CleanupPrompt.isPlausible("What's the capital of France?", raw: raw))
        XCTAssertFalse(CleanupPrompt.isPlausible(
            "The capital of France is Paris. It is known for the Eiffel Tower, the Louvre, and its cafés.", raw: raw))
        XCTAssertFalse(CleanupPrompt.isPlausible("", raw: raw))
    }

    func testAppCategories() {
        XCTAssertEqual(AppCategory.from(bundleID: "com.tinyspeck.slackmacgap"), .chat)
        XCTAssertEqual(AppCategory.from(bundleID: "com.apple.mail"), .email)
        XCTAssertEqual(AppCategory.from(bundleID: "com.microsoft.VSCode"), .code)
        XCTAssertEqual(AppCategory.from(bundleID: "com.apple.Notes"), .document)
        XCTAssertEqual(AppCategory.from(bundleID: "com.google.Chrome", windowTitle: "Inbox (3) - Gmail"), .email)
        XCTAssertEqual(AppCategory.from(bundleID: "com.google.Chrome", windowTitle: "Weather"), .general)
        XCTAssertEqual(AppCategory.from(bundleID: "org.example.unknown"), .general)
    }

    func testUserMessageIncludesToneAndCursorText() throws {
        var context = self.context
        context.category = .chat
        context.precedingText = "I was going to say"
        let message = try CleanupPrompt.userMessage(raw: "<b>hi</b>", context: context)
        XCTAssertTrue(message.contains("Chat message"))
        XCTAssertTrue(message.contains("I was going to say"))
        XCTAssertTrue(message.contains("&lt;b&gt;hi&lt;/b&gt;"))
        context.style = .formal
        XCTAssertTrue(try CleanupPrompt.userMessage(raw: "x", context: context).contains("professional punctuation"))
    }

    func testSilenceTrimKeepsSpeechWithMargin() {
        let rate = RecordedAudio.sampleRate
        let quiet = [Float](repeating: 0.0005, count: rate)
        let speech = (0..<rate / 2).map { Float(sin(Double($0) / 8) * 0.2) }
        let trimmed = RecordedAudio(samples: quiet + speech + quiet).trimmingSilence(padding: 0.3)
        XCTAssertLessThan(trimmed.duration, 1.3)
        XCTAssertGreaterThan(trimmed.duration, 1.0)
        let silent = RecordedAudio(samples: quiet + quiet)
        XCTAssertEqual(silent.trimmingSilence().samples.count, silent.samples.count)
    }

    @MainActor func testImplausibleCleanupFallsBackToTranscript() async {
        let inserter = RecordingInserter()
        let pipeline = DictationPipeline(inserter: inserter)
        let answer = String(repeating: "Paris is the capital and largest city of France. ", count: 4)
        pipeline.submit(audio: audio, context: context, transcriber: SampleTextProvider(text: "what is the capital of France"),
                        cleaner: FixedCleanup(output: answer))
        await pipeline.waitUntilIdle()
        XCTAssertEqual(inserter.inserted, ["what is the capital of France"])
    }

    @MainActor func testCursorTextAddsSpaceAndReachesCleanupOnlyWhenShared() async throws {
        for share in [true, false] {
            let inserter = RecordingInserter()
            let capture = ContextCapture()
            let pipeline = DictationPipeline(inserter: inserter)
            let cursor = Task { CursorContext(precedingText: "Earlier sentence.", windowTitle: nil) }
            pipeline.submit(audio: audio, context: context, transcriber: SampleTextProvider(text: " this is a new thought"),
                            cleaner: capture, cursor: cursor, shareCursorText: share)
            await pipeline.waitUntilIdle()
            XCTAssertEqual(inserter.inserted, [" this is a new thought"])
            let seen = await capture.seen
            XCTAssertEqual(seen?.precedingText, share ? "Earlier sentence." : nil)
            XCTAssertEqual(seen?.category, .document)
        }
    }

    func testGroqRequestContract() async throws {
        let transport = FixtureTransport(#"{"choices":[{"message":{"content":"Send it Wednesday."},"finish_reason":"stop"}]}"#)
        let provider = GroqCleanupProvider(authorize: { "unit-test-key" }, transport: transport)
        let result = try await provider.clean(raw: "um so like send it tuesday no wednesday", context: context)
        XCTAssertEqual(result, "Send it Wednesday.")
        let requests = await transport.requests
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://api.groq.com/openai/v1/chat/completions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer unit-test-key")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, GroqCleanupProvider.defaultModel)
        XCTAssertEqual(body["reasoning_effort"] as? String, "none")
        let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
        XCTAssertTrue(messages[0]["content"]?.contains("Never answer questions") == true)
        XCTAssertTrue(messages[1]["content"]?.contains("<transcript>") == true)
    }

    func testGroqTruncatedOutputAndShortClips() async throws {
        let truncated = FixtureTransport(#"{"choices":[{"message":{"content":"half"},"finish_reason":"length"}]}"#)
        let provider = GroqCleanupProvider(authorize: { "unit-test-key" }, transport: truncated)
        do { _ = try await provider.clean(raw: "one two three four", context: context); XCTFail("Expected rejection") }
        catch CloudError.invalidResponse { }
        let unused = FixtureTransport()
        let short = try await GroqCleanupProvider(authorize: { "k" }, transport: unused).clean(raw: "three short words", context: context)
        XCTAssertEqual(short, "three short words")
        let count = await unused.requests.count
        XCTAssertEqual(count, 0)
    }

    @MainActor func testCleanupNoteSaysWhichServiceRanAndWhatHappened() async {
        let cases: [(String, (any CleanupProvider)?, String?)] = [
            ("um send the report today", NamedCleanup(output: "Send the report today."), "Cleaned by Groq"),
            ("send the report today", NamedCleanup(output: "send the report today"), "Groq made no changes"),
            ("um send the report today", NamedCleanup(output: nil), "Groq error 401 · raw text"),
            ("send it", NamedCleanup(output: "Send it."), "Cleanup skipped · under 4 words"),
            ("um send the report today", nil, nil),
        ]
        for (spoken, cleaner, expected) in cases {
            let pipeline = DictationPipeline(inserter: RecordingInserter())
            pipeline.submit(audio: audio, context: context, transcriber: SampleTextProvider(text: spoken), cleaner: cleaner)
            await pipeline.waitUntilIdle()
            if let expected { XCTAssertTrue(pipeline.lastCleanupNote?.hasPrefix(expected) == true, "\(String(describing: pipeline.lastCleanupNote))") }
            else { XCTAssertNil(pipeline.lastCleanupNote) }
        }
    }
}

private final class LegacyKeys: CredentialStore, @unchecked Sendable {
    var values: [CloudService: String]
    var reads = 0
    init(_ values: [CloudService: String]) { self.values = values }
    func read(_ service: CloudService) -> String? { reads += 1; return values[service] }
    func save(_ value: String, for service: CloudService) { values[service] = value }
    func delete(_ service: CloudService) { values[service] = nil }
}

final class CredentialFileTests: XCTestCase {
    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("UtterTests-\(UUID().uuidString)/Credentials/api-keys.json")
    }

    func testFileIsOwnerOnlyAndRoundTrips() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent().deletingLastPathComponent()) }
        let store = FileCredentialStore(url: url)
        XCTAssertFalse(try store.exists(.groq))
        try store.save("  gsk_test  ", for: .groq)
        XCTAssertEqual(try store.read(.groq), "gsk_test")
        let fileMode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        let folderMode = try FileManager.default.attributesOfItem(atPath: url.deletingLastPathComponent().path)[.posixPermissions] as? Int
        XCTAssertEqual(fileMode, 0o600)
        XCTAssertEqual(folderMode, 0o700)
        try store.delete(.groq)
        XCTAssertNil(try store.read(.groq))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertThrowsError(try store.save("bad\nkey", for: .groq))
    }

    func testLegacyKeychainKeyMovesToFileOnce() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent().deletingLastPathComponent()) }
        let legacy = LegacyKeys([.groq: "old-key"])
        let store = MigratingCredentialStore(primary: FileCredentialStore(url: url), legacy: legacy)
        XCTAssertTrue(try store.exists(.groq))
        XCTAssertEqual(try store.read(.groq), "old-key")
        XCTAssertNil(legacy.values[.groq])
        XCTAssertEqual(try FileCredentialStore(url: url).read(.groq), "old-key")
        let readsAfterMigration = legacy.reads
        XCTAssertEqual(try store.read(.groq), "old-key")
        XCTAssertEqual(legacy.reads, readsAfterMigration)
    }
}

private actor SequenceTransport: CloudTransport {
    private var responses: [(String, Int)]
    private(set) var models: [String] = []
    init(_ responses: [(String, Int)]) { self.responses = responses }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
        models.append(body?["model"] as? String ?? "")
        let next = responses.removeFirst()
        return (Data(next.0.utf8), next.1)
    }
}

final class GroqFallbackTests: XCTestCase {
    func testRateLimitedModelRetriesOnOtherFastModel() async throws {
        let ok = #"{"choices":[{"message":{"content":"Send it Wednesday."},"finish_reason":"stop"}]}"#
        let transport = SequenceTransport([("{}", 429), (ok, 200)])
        let provider = GroqCleanupProvider(model: "qwen/qwen3.8-27b", authorize: { "k" }, transport: transport)
        let context = DictationContext(target: .init(processID: 1, appName: "Notes", bundleID: "com.apple.Notes"))
        let result = try await provider.clean(raw: "send it tuesday no wednesday", context: context)
        XCTAssertEqual(result, "Send it Wednesday.")
        let models = await transport.models
        XCTAssertEqual(models, ["qwen/qwen3.8-27b", "openai/gpt-oss-120b"])
        XCTAssertEqual(GroqCleanupProvider.fastestReasoning(for: "qwen/qwen3.8-27b"), "none")
    }
}

final class GroqUsageTests: XCTestCase {
    func testDurationParsing() {
        XCTAssertEqual(GroqUsageStore.seconds("3h7m12s"), 11232)
        XCTAssertEqual(GroqUsageStore.seconds("1m26.4s") ?? 0, 86.4, accuracy: 0.001)
        XCTAssertEqual(GroqUsageStore.seconds("577ms") ?? 0, 0.577, accuracy: 0.001)
        XCTAssertNil(GroqUsageStore.seconds("soon"))
    }

    func testRecordsHeadersAndEstimatesRefill() throws {
        let suite = "UtterUsage-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = GroqUsageStore(defaults: defaults)
        let start = Date(timeIntervalSince1970: 1_000_000)
        let response = try XCTUnwrap(HTTPURLResponse(url: URL(fileURLWithPath: "/"), statusCode: 200, httpVersion: nil, headerFields: [
            "x-ratelimit-limit-requests": "1000", "x-ratelimit-remaining-requests": "800", "x-ratelimit-reset-requests": "1h",
        ]))
        store.record(model: "qwen/qwen3.8-27b", response: response, now: start)
        let snapshot = try XCTUnwrap(GroqUsageStore(defaults: defaults).all().first)
        XCTAssertEqual(snapshot.title, "Cleanup · qwen3.8-27b")
        XCTAssertEqual(snapshot.estimatedRemaining(at: start), 800)
        XCTAssertEqual(snapshot.estimatedRemaining(at: start.addingTimeInterval(1800)), 900)
        XCTAssertEqual(snapshot.estimatedRemaining(at: start.addingTimeInterval(7200)), 1000)
        XCTAssertFalse(snapshot.isLow(at: start))
        let low = GroqUsageSnapshot(model: "whisper-large-v3-turbo", limit: 2000, remaining: 150, secondsUntilFull: 80000, updated: start)
        XCTAssertTrue(low.isLow(at: start))
        XCTAssertEqual(low.title, "Speech to text")
    }

    @MainActor func testMenuShowsOneLinePerModel() {
        let now = Date()
        let items = AppDelegate.usageMenuItems([
            GroqUsageSnapshot(model: "whisper-large-v3-turbo", limit: 2000, remaining: 1998, secondsUntilFull: 86, updated: now),
            GroqUsageSnapshot(model: "qwen/qwen3.8-27b", limit: 1000, remaining: 870, secondsUntilFull: 11232, updated: now),
        ], now: now)
        XCTAssertEqual(items.map(\.title), ["Groq · left today", "Speech to text: 1,998 of 2,000 · full in 2m",
                                            "Cleanup · qwen3.8-27b: 870 of 1,000 · full in 3h 8m", ""])
        XCTAssertTrue(AppDelegate.usageMenuItems([], now: now).isEmpty)
    }
}

final class UsageLevelTests: XCTestCase {
    func testColourBands() {
        XCTAssertEqual(UsageLevel(fraction: 1), .plenty)
        XCTAssertEqual(UsageLevel(fraction: 0.6), .plenty)
        XCTAssertEqual(UsageLevel(fraction: 0.59), .middling)
        XCTAssertEqual(UsageLevel(fraction: 0.4), .middling)
        XCTAssertEqual(UsageLevel(fraction: 0.39), .low)
        XCTAssertEqual(UsageLevel(fraction: 0), .low)
    }

    @MainActor func testMenuRowsUseBarViews() {
        let now = Date()
        let items = AppDelegate.usageMenuItems([
            GroqUsageSnapshot(model: "whisper-large-v3-turbo", limit: 2000, remaining: 2000, secondsUntilFull: 0, updated: now),
        ], now: now)
        XCTAssertNotNil(items[1].view)
        XCTAssertGreaterThan(items[1].view?.frame.height ?? 0, 30)
    }
}
