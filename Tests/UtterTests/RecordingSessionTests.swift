import XCTest
@testable import Utter

@MainActor
private final class FakeRecorder: AudioRecorder {
    var level: Float = 0.5
    var failure: String?
    var startError = false
    var stopError = false
    var starts = 0
    var stops = 0
    var cancels = 0
    func start() throws {
        if startError { throw RecordingError.message("Microphone denied") }
        starts += 1
    }
    func stop() throws -> RecordedAudio {
        stops += 1
        if stopError { throw RecordingError.message("Microphone disconnected") }
        return RecordedAudio(samples: Array(repeating: 0, count: 16_000))
    }
    func cancel() { cancels += 1 }
}

@MainActor
private final class FakeOverlay: OverlayController {
    var states: [OverlayState] = []
    var hides = 0
    func show(_ state: OverlayState) { states.append(state) }
    func hide() { hides += 1 }
}

@MainActor
private final class ClockBox { var value: TimeInterval = 0 }

final class RecordingSessionTests: XCTestCase {
    @MainActor private func fixture() -> (RecordingSession, FakeRecorder, FakeOverlay, ClockBox) {
        let recorder = FakeRecorder()
        let overlay = FakeOverlay()
        let clock = ClockBox()
        let session = RecordingSession(recorder: recorder, overlay: overlay, now: { clock.value })
        return (session, recorder, overlay, clock)
    }
    @MainActor func testHoldReleaseDeliversClip() async {
        let (session, recorder, _, clock) = fixture()
        var clips = 0
        session.onClip = { _ in clips += 1 }
        session.handle(.down)
        clock.value = 1
        session.handle(.up)
        XCTAssertEqual(recorder.starts, 1)
        XCTAssertEqual(recorder.stops, 1)
        XCTAssertEqual(clips, 1)
        XCTAssertFalse(session.isRecording)
        session.cancel()
    }
    @MainActor func testAccidentalTapIsDiscarded() async {
        let (session, recorder, overlay, clock) = fixture()
        session.onClip = { _ in XCTFail("Short tap must not deliver audio") }
        session.handle(.down)
        clock.value = 0.249
        session.handle(.up)
        XCTAssertEqual(recorder.stops, 0)
        XCTAssertEqual(recorder.cancels, 1)
        XCTAssertEqual(overlay.hides, 1)
        session.cancel()
    }
    @MainActor func testQuarterSecondBoundaryIsAccepted() async {
        let (session, recorder, _, clock) = fixture()
        session.handle(.down)
        clock.value = 0.25
        session.handle(.up)
        XCTAssertEqual(recorder.stops, 1)
        session.cancel()
    }
    @MainActor func testDuplicateDownDoesNotRestartRecording() async {
        let (session, recorder, _, _) = fixture()
        session.handle(.down); session.handle(.down)
        XCTAssertEqual(recorder.starts, 1)
        session.cancel()
    }
    @MainActor func testReleaseWithoutPressDoesNothing() async {
        let (session, recorder, _, _) = fixture()
        session.handle(.up)
        XCTAssertEqual(recorder.stops, 0)
        session.cancel()
    }
    @MainActor func testRapidClipsAreNotDropped() async {
        let (session, recorder, _, clock) = fixture()
        var clips = 0
        session.onClip = { _ in clips += 1 }
        for _ in 0..<100 {
            session.handle(.down)
            clock.value += 1
            session.handle(.up)
        }
        XCTAssertEqual(recorder.starts, 100)
        XCTAssertEqual(clips, 100)
        session.cancel()
    }
    @MainActor func testCapRequiresReleaseBeforeNewRecording() async {
        let (session, recorder, _, clock) = fixture()
        session.handle(.down)
        clock.value = 300
        session.finish()
        session.handle(.down)
        XCTAssertEqual(recorder.starts, 1)
        session.handle(.up)
        session.handle(.down)
        XCTAssertEqual(recorder.starts, 2)
        session.cancel()
    }
    @MainActor func testCancellationDiscardsAndResets() async {
        let (session, recorder, overlay, _) = fixture()
        session.onClip = { _ in XCTFail("Cancelled audio must be discarded") }
        session.handle(.down)
        session.handle(.cancel)
        XCTAssertFalse(session.isRecording)
        XCTAssertEqual(recorder.cancels, 1)
        XCTAssertEqual(overlay.hides, 1)
        session.handle(.down)
        XCTAssertTrue(session.isRecording)
        session.cancel()
    }
    @MainActor func testStartFailureDisplaysErrorAndCanRetry() async {
        let (session, recorder, overlay, _) = fixture()
        recorder.startError = true
        session.handle(.down)
        XCTAssertFalse(session.isRecording)
        XCTAssertEqual(overlay.states.last, .error("Microphone denied"))
        recorder.startError = false
        session.handle(.up); session.handle(.down)
        XCTAssertTrue(session.isRecording)
        session.cancel()
    }
    @MainActor func testStopFailureDoesNotDeliverClip() async {
        let (session, recorder, overlay, clock) = fixture()
        session.onClip = { _ in XCTFail("Failed audio must not be delivered") }
        recorder.stopError = true
        session.handle(.down)
        clock.value = 1
        session.handle(.up)
        XCTAssertEqual(overlay.states.last, .error("Microphone disconnected"))
        XCTAssertFalse(session.isRecording)
        session.cancel()
    }
    @MainActor func testMeterAndElapsedTime() async {
        let (session, _, overlay, clock) = fixture()
        session.handle(.down)
        clock.value = 12
        session.refreshMeter()
        XCTAssertEqual(overlay.states.last, .listening(level: 0.5, seconds: 12))
        session.cancel()
    }
    @MainActor func testRenderFailureCancelsCapture() async {
        let (session, recorder, overlay, _) = fixture()
        session.handle(.down)
        recorder.failure = "Conversion failed"
        session.refreshMeter()
        XCTAssertFalse(session.isRecording)
        XCTAssertEqual(overlay.states.last, .error("Conversion failed"))
        session.cancel()
    }
    @MainActor func testOldCompletionDoesNotHideNewRecording() async {
        let (session, _, overlay, _) = fixture()
        session.handle(.down)
        session.completed("Old clip saved")
        XCTAssertEqual(overlay.states.last, .listening(level: 0, seconds: 0))
        session.cancel()
    }
}
