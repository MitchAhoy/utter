import XCTest
@testable import Utter

@MainActor
private final class FakeInserter: TextInserter {
    var inserted: [String] = []
    var targets: [InsertionTarget] = []
    var recovered: [String] = []
    var failInsertion = false
    var failRecovery = false
    func insert(_ text: String, target: InsertionTarget) async throws {
        if failInsertion { throw InsertionError.secureInput }
        inserted.append(text)
        targets.append(target)
    }
    func copyForRecovery(_ text: String) throws {
        if failRecovery { throw InsertionError.clipboardUnavailable }
        recovered.append(text)
    }
}

private struct FailingTranscriber: TranscriptionProvider {
    func transcribe(audio: RecordedAudio, language: String?, prompt: String?) async throws -> String {
        throw RecordingError.message("Offline")
    }
}

private struct SlowTranscriber: TranscriptionProvider {
    let started: AsyncStream<Void>.Continuation?
    func transcribe(audio: RecordedAudio, language: String?, prompt: String?) async throws -> String {
        started?.yield(())
        try await Task.sleep(for: .seconds(60))
        return "must never paste"
    }
}

private struct BriefTranscriber: TranscriptionProvider {
    let started: AsyncStream<Void>.Continuation
    func transcribe(audio: RecordedAudio, language: String?, prompt: String?) async throws -> String {
        started.yield(())
        try await Task.sleep(for: .milliseconds(50))
        return "first"
    }
}

private struct FailingCleanup: CleanupProvider {
    func clean(raw: String, context: DictationContext) async throws -> String {
        throw RecordingError.message("Cleanup failed")
    }
}

private struct SlowCleanup: CleanupProvider {
    func clean(raw: String, context: DictationContext) async throws -> String {
        try await Task.sleep(for: .seconds(60))
        return "too late"
    }
}

private struct EmptyCleanup: CleanupProvider {
    func clean(raw: String, context: DictationContext) async throws -> String { " \n " }
}

final class DictationPipelineTests: XCTestCase {
    private let audio = RecordedAudio(samples: [0, 0.1])
    private let context = DictationContext(target: InsertionTarget(processID: 42, appName: "Notes", bundleID: "com.apple.Notes"))

    @MainActor func testSampleTraversesPipelineAndPreservesTarget() async {
        let inserter = FakeInserter()
        let pipeline = DictationPipeline(inserter: inserter)
        pipeline.submit(audio: audio, context: context, transcriber: SampleTextProvider(text: "sample"))
        await pipeline.waitUntilIdle()
        XCTAssertEqual(inserter.inserted, ["sample"])
        XCTAssertEqual(inserter.targets, [context.target])
        XCTAssertEqual(inserter.recovered, [])
    }

    @MainActor func testQueuedClipsInsertInOrder() async {
        let inserter = FakeInserter()
        let pipeline = DictationPipeline(inserter: inserter)
        for word in ["first", "second", "third"] {
            XCTAssertTrue(pipeline.submit(audio: audio, context: context, transcriber: SampleTextProvider(text: word)))
        }
        await pipeline.waitUntilIdle()
        XCTAssertEqual(inserter.inserted, ["first", "second", "third"])
    }

    @MainActor func testNextClipCanArriveWhilePreviousIsProcessing() async {
        let inserter = FakeInserter()
        let started = AsyncStream.makeStream(of: Void.self)
        let pipeline = DictationPipeline(inserter: inserter)
        pipeline.submit(audio: audio, context: context, transcriber: BriefTranscriber(started: started.continuation))
        for await _ in started.stream { break }
        XCTAssertTrue(pipeline.submit(audio: audio, context: context, transcriber: SampleTextProvider(text: "second")))
        await pipeline.waitUntilIdle()
        started.continuation.finish()
        XCTAssertEqual(inserter.inserted, ["first", "second"])
    }

    @MainActor func testQueueBoundIsVisibleAndResetsAfterDrain() async {
        let inserter = FakeInserter()
        let pipeline = DictationPipeline(inserter: inserter)
        var events: [PipelineEvent] = []
        pipeline.onEvent = { events.append($0) }
        for _ in 0..<3 { XCTAssertTrue(pipeline.submit(audio: audio, context: context, transcriber: SampleTextProvider(text: "clip"))) }
        XCTAssertFalse(pipeline.canAcceptClip)
        XCTAssertFalse(pipeline.submit(audio: audio, context: context, transcriber: SampleTextProvider(text: "fourth")))
        await pipeline.waitUntilIdle()
        XCTAssertTrue(pipeline.canAcceptClip)
        XCTAssertEqual(inserter.inserted.count, 3)
        XCTAssertTrue(events.contains(.failed(PipelineError.queueFull.localizedDescription)))
    }

    @MainActor func testTranscriptionFailureDoesNotReplaceClipboardWithNothing() async {
        let inserter = FakeInserter()
        let pipeline = DictationPipeline(inserter: inserter)
        var events: [PipelineEvent] = []
        pipeline.onEvent = { events.append($0) }
        pipeline.submit(audio: audio, context: context, transcriber: FailingTranscriber())
        await pipeline.waitUntilIdle()
        XCTAssertEqual(inserter.inserted, [])
        XCTAssertEqual(inserter.recovered, [])
        XCTAssertTrue(events.contains(.failed("Offline")))
    }

    @MainActor func testInsertionFailureRecoversRawText() async {
        let inserter = FakeInserter()
        inserter.failInsertion = true
        let pipeline = DictationPipeline(inserter: inserter)
        var events: [PipelineEvent] = []
        pipeline.onEvent = { events.append($0) }
        pipeline.submit(audio: audio, context: context, transcriber: SampleTextProvider(text: "raw transcript"))
        await pipeline.waitUntilIdle()
        XCTAssertEqual(inserter.recovered, ["raw transcript"])
        XCTAssertTrue(events.contains(.failed("Can't type into a secure field Text copied to clipboard.")))
    }

    @MainActor func testRecoveryFailureIsReportedHonestly() async {
        let inserter = FakeInserter()
        inserter.failInsertion = true
        inserter.failRecovery = true
        let pipeline = DictationPipeline(inserter: inserter)
        var events: [PipelineEvent] = []
        pipeline.onEvent = { events.append($0) }
        pipeline.submit(audio: audio, context: context, transcriber: SampleTextProvider(text: "raw"))
        await pipeline.waitUntilIdle()
        XCTAssertTrue(events.contains(.failed("Can't type into a secure field Could not copy text to clipboard.")))
    }

    @MainActor func testCleanupFailureFallsBackToRawText() async {
        let inserter = FakeInserter()
        let pipeline = DictationPipeline(inserter: inserter, cleanup: FailingCleanup())
        pipeline.submit(audio: audio, context: context, transcriber: SampleTextProvider(text: "raw words remain intact"))
        await pipeline.waitUntilIdle()
        XCTAssertEqual(inserter.inserted, ["raw words remain intact"])
    }

    @MainActor func testCleanupTimeoutFallsBackToRawText() async {
        let inserter = FakeInserter()
        let pipeline = DictationPipeline(inserter: inserter, cleanup: SlowCleanup(), cleanupTimeout: .milliseconds(20))
        pipeline.submit(audio: audio, context: context, transcriber: SampleTextProvider(text: "raw words remain intact"))
        await pipeline.waitUntilIdle()
        XCTAssertEqual(inserter.inserted, ["raw words remain intact"])
    }

    @MainActor func testEmptyCleanupCannotLoseTranscript() async {
        let inserter = FakeInserter()
        let pipeline = DictationPipeline(inserter: inserter, cleanup: EmptyCleanup())
        pipeline.submit(audio: audio, context: context, transcriber: SampleTextProvider(text: "raw"))
        await pipeline.waitUntilIdle()
        XCTAssertEqual(inserter.inserted, ["raw"])
    }

    @MainActor func testTranscriptionTimeoutDoesNotPaste() async {
        let inserter = FakeInserter()
        let pipeline = DictationPipeline(inserter: inserter, transcriptionTimeout: .milliseconds(20))
        pipeline.submit(audio: audio, context: context, transcriber: SlowTranscriber(started: nil))
        await pipeline.waitUntilIdle()
        XCTAssertEqual(inserter.inserted, [])
    }

    @MainActor func testCancelDropsPendingClipsWithoutChangingClipboard() async {
        let inserter = FakeInserter()
        let started = AsyncStream.makeStream(of: Void.self)
        let pipeline = DictationPipeline(inserter: inserter)
        pipeline.submit(audio: audio, context: context, transcriber: SlowTranscriber(started: started.continuation))
        pipeline.submit(audio: audio, context: context, transcriber: SampleTextProvider(text: "pending"))
        for await _ in started.stream { break }
        pipeline.cancel()
        // A new clip arrives before the cancelled provider has finished unwinding.
        XCTAssertTrue(pipeline.submit(audio: audio, context: context, transcriber: SampleTextProvider(text: "new clip")))
        await pipeline.waitUntilIdle()
        started.continuation.finish()
        XCTAssertEqual(inserter.inserted, ["new clip"])
        XCTAssertEqual(inserter.recovered, [])
        XCTAssertTrue(pipeline.canAcceptClip)
    }

    @MainActor func testEmptyTranscriptDoesNotPaste() async {
        let inserter = FakeInserter()
        let pipeline = DictationPipeline(inserter: inserter)
        pipeline.submit(audio: audio, context: context, transcriber: SampleTextProvider(text: " \n "))
        await pipeline.waitUntilIdle()
        XCTAssertEqual(inserter.inserted, [])
        XCTAssertEqual(inserter.recovered, [])
    }
}
