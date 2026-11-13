import SwiftUI
import XCTest
@testable import Utter

// MARK: Test doubles

private func tone(_ seconds: Double, level: Float = 0.1) -> [Float] {
    (0..<Int(seconds * 16_000)).map { level * sin(Float($0) * 0.2) }
}
private func quiet(_ seconds: Double) -> [Float] { Array(repeating: 0, count: Int(seconds * 16_000)) }
private func loudness(_ samples: [Float]) -> Float {
    (samples.reduce(Float(0)) { $0 + $1 * $1 } / Float(max(1, samples.count))).squareRoot()
}

private actor ScriptedChat: ChatProvider {
    struct Request: Sendable { let system: String; let turns: [ChatTurn] }
    private var replies: [Result<String, CloudError>]
    private(set) var requests: [Request] = []
    init(_ replies: [Result<String, CloudError>]) { self.replies = replies }
    init(_ reply: String) { replies = [.success(reply)] }
    func reply(system: String, turns: [ChatTurn], maxTokens: Int) async throws -> String {
        requests.append(Request(system: system, turns: turns))
        // The last scripted reply repeats.
        let next = replies.count > 1 ? replies.removeFirst() : replies[0]
        return try next.get()
    }
}

private actor ScriptedSpeech: TranscriptionProvider {
    private var replies: [Result<String, CloudError>]
    private(set) var calls = 0
    init(_ replies: [Result<String, CloudError>]) { self.replies = replies }
    func transcribe(audio: RecordedAudio, language: String?, prompt: String?) async throws -> String {
        calls += 1
        let next = replies.count > 1 ? replies.removeFirst() : replies[0]
        return try next.get()
    }
}

/// Answers each chunk with text chosen by its start time, after an optional delay.
private struct TimedSpeech: TranscriptionProvider {
    let texts: [Int: String]
    var delays: [Int: Duration] = [:]
    func transcribe(audio: RecordedAudio, language: String?, prompt: String?) async throws -> String {
        let key = Int(audio.samples.first ?? 0)
        if let delay = delays[key] { try await Task.sleep(for: delay) }
        return texts[key] ?? ""
    }
}

private actor Waits {
    private(set) var taken: [Duration] = []
    func add(_ wait: Duration) { taken.append(wait) }
}

@MainActor
private final class FakeCapture: MeetingCapturing {
    var onChunk: (@MainActor (Speaker, SpeechChunk) -> Void)?
    var microphonePaused = false
    var heardSystemAudio = true
    var startError: Error?
    private(set) var started: [(uid: String, offset: TimeInterval)] = []
    private(set) var stops = 0
    func start(microphoneUID: String, offset: TimeInterval) throws {
        if let startError { throw startError }
        started.append((microphoneUID, offset))
    }
    func stop() { stops += 1 }
    /// The first sample carries the key that `TimedSpeech` answers by.
    func say(_ speaker: Speaker, at start: TimeInterval, key: Int, seconds: Double = 4) {
        var samples = Array(repeating: Float(0.1), count: Int(seconds * 16_000))
        samples[0] = Float(key)
        onChunk?(speaker, SpeechChunk(start: start, audio: RecordedAudio(samples: samples)))
    }
}

private func segment(_ start: TimeInterval, _ speaker: Speaker, _ text: String, meeting: String = "m") -> TranscriptSegment {
    TranscriptSegment(meeting: meeting, speaker: speaker, start: start, text: text)
}

private func temporaryStore() -> MeetingStore {
    MeetingStore(directory: FileManager.default.temporaryDirectory.appending(path: "utter-meetings-\(UUID().uuidString)"))
}

// MARK: Segmenter

final class SpeechSegmenterTests: XCTestCase {
    func testSilenceProducesNothing() {
        var segmenter = SpeechSegmenter()
        XCTAssertTrue(segmenter.append(quiet(20)).isEmpty)
        XCTAssertTrue(segmenter.finish().isEmpty)
    }

    func testSpeechThenLongPauseIsOneChunkWithItsStartTime() throws {
        var segmenter = SpeechSegmenter()
        let chunks = segmenter.append(quiet(1) + tone(3) + quiet(3))
        let chunk = try XCTUnwrap(chunks.first)
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunk.start, 0.7, accuracy: 0.05, "starts just before the first word")
        XCTAssertEqual(chunk.audio.duration, 3.6, accuracy: 0.1, "speech plus a short margin each side")
        XCTAssertTrue(segmenter.finish().isEmpty)
    }

    func testShortPausesDoNotSplitUntilTheChunkIsLongEnough() {
        var segmenter = SpeechSegmenter()
        // Three sentences with 0.8 s pauses: the first two stay together, the cut comes once past eight seconds.
        let chunks = segmenter.append(tone(3) + quiet(0.8) + tone(3) + quiet(0.8) + tone(3) + quiet(0.8) + tone(2) + quiet(3))
        XCTAssertEqual(chunks.count, 2)
        XCTAssertEqual(chunks[0].audio.duration, 10.9, accuracy: 0.05)
        XCTAssertEqual(chunks[1].start, 11.2, accuracy: 0.05)
    }

    func testNonStopSpeechIsCutAtTheHardLimit() {
        var segmenter = SpeechSegmenter()
        let chunks = segmenter.append(tone(70)) + segmenter.finish()
        XCTAssertEqual(chunks.count, 3)
        for chunk in chunks { XCTAssertLessThanOrEqual(chunk.audio.duration, 30.01) }
        XCTAssertEqual(chunks.map(\.audio.duration).reduce(0, +), 70, accuracy: 0.1, "no speech is lost at the cuts")
    }

    func testLongSpeechPrefersABriefGapOverCuttingAWord() {
        var segmenter = SpeechSegmenter()
        let chunks = segmenter.append(tone(22) + quiet(0.3) + tone(5) + quiet(3))
        XCTAssertEqual(chunks.count, 2)
        XCTAssertEqual(chunks[0].audio.duration, 22.3, accuracy: 0.1)
    }

    func testClicksAreDropped() {
        var segmenter = SpeechSegmenter()
        XCTAssertTrue((segmenter.append(quiet(1) + tone(0.1) + quiet(4)) + segmenter.finish()).isEmpty)
    }

    func testNoChunkIsSilentAndSmallBuffersGiveTheSameResult() {
        let stream = quiet(2) + tone(4) + quiet(5) + tone(6) + quiet(4)
        var whole = SpeechSegmenter()
        let expected = whole.append(stream) + whole.finish()
        var pieces = SpeechSegmenter()
        var found: [SpeechChunk] = []
        var index = 0
        while index < stream.count {
            let end = min(stream.count, index + 4_001)
            found += pieces.append(Array(stream[index..<end]))
            index = end
        }
        found += pieces.finish()
        XCTAssertEqual(found.map(\.start), expected.map(\.start))
        XCTAssertEqual(found.map(\.audio.samples.count), expected.map(\.audio.samples.count))
        XCTAssertEqual(found.count, 2)
        for chunk in found { XCTAssertGreaterThan(loudness(chunk.audio.samples), 0.05) }
    }

    func testSteadyBackgroundNoiseIsNotSpeech() {
        var segmenter = SpeechSegmenter()
        let hiss = (0..<16_000 * 30).map { _ in Float.random(in: -0.003...0.003) }
        XCTAssertTrue((segmenter.append(hiss) + segmenter.finish()).isEmpty)
    }

    func testResyncContinuesFromTheMeetingClock() throws {
        var segmenter = SpeechSegmenter()
        XCTAssertEqual(segmenter.append(tone(2)).count, 0)
        let flushed = segmenter.resync(to: 100)
        XCTAssertEqual(flushed.count, 1, "speech in progress is kept")
        let later = segmenter.append(quiet(1) + tone(2) + quiet(3))
        XCTAssertEqual(try XCTUnwrap(later.first).start, 100.7, accuracy: 0.05)
    }
}

// MARK: Store

final class MeetingStoreTests: XCTestCase {
    func testMeetingRoundTripAndOrder() async throws {
        let store = temporaryStore()
        let old = Meeting(id: "a", title: "Old", started: Date(timeIntervalSince1970: 100), ended: Date(timeIntervalSince1970: 200),
                          notes: "my notes", enhanced: "## Summary", template: "stand-up")
        let recent = Meeting(id: "b", title: "Recent", started: Date(timeIntervalSince1970: 300))
        try await store.save(old); try await store.save(recent)
        let all = try await store.meetings()
        XCTAssertEqual(all, [recent, old])
        var changed = old; changed.title = "Renamed"; changed.ended = nil
        try await store.save(changed)
        let reread = try await store.meeting(id: "a")
        XCTAssertEqual(reread, changed)
        let count = try await store.meetings().count
        XCTAssertEqual(count, 2, "saving again updates, never duplicates")
    }

    func testSegmentsComeBackInSpokenOrder() async throws {
        let store = temporaryStore()
        for item in [segment(30, .them, "third"), segment(5, .me, "first"), segment(12, .them, "second")] { try await store.add(item) }
        let lines = try await store.segments(meeting: "m")
        XCTAssertEqual(lines.map(\.text), ["first", "second", "third"])
        XCTAssertEqual(lines.map(\.speaker), [.me, .them, .them])
        XCTAssertEqual(Set(lines.map(\.id)).count, 3)
    }

    func testSearchFindsTitleNotesAndTranscript() async throws {
        let store = temporaryStore()
        try await store.save(Meeting(id: "a", title: "Budget review", started: Date(timeIntervalSince1970: 1)))
        try await store.save(Meeting(id: "b", title: "Weekly", started: Date(timeIntervalSince1970: 2), notes: "ask about the Lisbon offsite"))
        try await store.save(Meeting(id: "c", title: "Sync", started: Date(timeIntervalSince1970: 3)))
        try await store.add(segment(1, .them, "The Kubernetes migration slipped", meeting: "c"))
        for (query, expected) in [("budget", ["a"]), ("LISBON", ["b"]), ("kubernetes", ["c"]), ("nothing-here", []), ("", ["c", "b", "a"])] {
            let found = try await store.meetings(search: query).map(\.id)
            XCTAssertEqual(found, expected, query)
        }
    }

    func testDeleteRemovesTranscriptAndQuestions() async throws {
        let store = temporaryStore()
        try await store.save(Meeting(id: "a", title: "Gone", started: Date()))
        try await store.save(Meeting(id: "b", title: "Kept", started: Date()))
        try await store.add(segment(1, .me, "secret plan", meeting: "a"))
        try await store.add(segment(1, .me, "kept line", meeting: "b"))
        try await store.add(ChatMessage(meeting: "a", fromUser: true, text: "q"))
        try await store.delete(meeting: "a")
        let meetings = try await store.meetings().map(\.id)
        let lines = try await store.segments(meeting: "a")
        let chat = try await store.chat(meeting: "a")
        let search = try await store.meetings(search: "secret")
        let kept = try await store.segments(meeting: "b").count
        XCTAssertEqual(meetings, ["b"]); XCTAssertTrue(lines.isEmpty); XCTAssertTrue(chat.isEmpty); XCTAssertTrue(search.isEmpty)
        XCTAssertEqual(kept, 1)
    }

    func testMatchingSegmentsRanksByWordsMatched() async throws {
        let store = temporaryStore()
        try await store.add(segment(1, .them, "We agreed the pricing page ships Friday", meeting: "a"))
        try await store.add(segment(2, .them, "Pricing is still open", meeting: "b"))
        try await store.add(segment(3, .me, "Lunch was good", meeting: "b"))
        let hits = try await store.matchingSegments(words: ["pricing", "friday", "of"])
        XCTAssertEqual(hits.map(\.meeting), ["a", "b"])
        let none = try await store.matchingSegments(words: ["of"])
        XCTAssertTrue(none.isEmpty, "very short words are not searched")
    }

    func testChatIsKeptPerMeetingAndClears() async throws {
        let store = temporaryStore()
        try await store.add(ChatMessage(meeting: "a", fromUser: true, text: "question"))
        try await store.add(ChatMessage(meeting: "a", fromUser: false, text: "answer"))
        try await store.add(ChatMessage(meeting: "", fromUser: true, text: "overall"))
        let first = try await store.chat(meeting: "a")
        XCTAssertEqual(first.map(\.text), ["question", "answer"]); XCTAssertEqual(first.map(\.fromUser), [true, false])
        try await store.clearChat(meeting: "a")
        let cleared = try await store.chat(meeting: "a")
        let overall = try await store.chat(meeting: "").count
        XCTAssertTrue(cleared.isEmpty); XCTAssertEqual(overall, 1)
    }

    func testDatabaseFileIsPrivateAndHoldsNoAudio() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "utter-meetings-\(UUID().uuidString)")
        let store = MeetingStore(directory: directory)
        try await store.save(Meeting(id: "a", title: "T", started: Date()))
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertTrue(files.allSatisfy { $0.hasPrefix("meetings.sqlite") }, "\(files)")
        let mode = try FileManager.default.attributesOfItem(atPath: directory.appending(path: "meetings.sqlite").path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
    }
}

// MARK: Transcriber

final class MeetingTranscriberTests: XCTestCase {
    private let chunk = SpeechChunk(start: 3, audio: RecordedAudio(samples: Array(repeating: 0.1, count: 16_000 * 4)))

    func testInventedPhrasesAreDropped() {
        XCTAssertTrue(MeetingTranscriber.isInvented("Thanks for watching!", duration: 10))
        XCTAssertTrue(MeetingTranscriber.isInvented("Subtitles by the Amara.org community", duration: 10))
        XCTAssertTrue(MeetingTranscriber.isInvented(" . ", duration: 10))
        XCTAssertTrue(MeetingTranscriber.isInvented("Thank you.", duration: 0.8))
        XCTAssertFalse(MeetingTranscriber.isInvented("Thank you.", duration: 3), "a real thank-you in a longer chunk is kept")
        XCTAssertFalse(MeetingTranscriber.isInvented("Thank you for the update on pricing.", duration: 0.8))
    }

    func testEchoNeedsMostWordsToMatch() {
        let played = ["So the launch is moving to the fourteenth of March", "and we need the pricing page by then"]
        XCTAssertTrue(MeetingTranscriber.isEcho("the launch is moving to the fourteenth of march", of: played))
        XCTAssertFalse(MeetingTranscriber.isEcho("I can have the pricing page done on Tuesday instead", of: played))
        XCTAssertFalse(MeetingTranscriber.isEcho("the launch", of: played), "too short to judge")
        XCTAssertFalse(MeetingTranscriber.isEcho("the the the the the", of: ["the launch"]), "a repeated word counts once per use")
    }

    func testRateLimitUsesTheOnDeviceModelWhenThereIsOne() async throws {
        let cloud = ScriptedSpeech([.failure(.http(429))])
        let local = ScriptedSpeech([.success("local words")])
        let waits = Waits()
        let transcriber = MeetingTranscriber(primary: cloud, fallback: local, sleep: { await waits.add($0) })
        let text = try await transcriber.text(for: chunk)
        let taken = await waits.taken
        XCTAssertEqual(text, "local words"); XCTAssertTrue(taken.isEmpty)
    }

    func testRateLimitWaitsAndRetriesWithoutAFallback() async throws {
        let cloud = ScriptedSpeech([.failure(.http(429)), .failure(.http(429)), .success("  finally  ")])
        let waits = Waits()
        let transcriber = MeetingTranscriber(primary: cloud, sleep: { await waits.add($0) })
        let text = try await transcriber.text(for: chunk)
        let taken = await waits.taken
        XCTAssertEqual(text, "finally"); XCTAssertEqual(taken, [.seconds(5), .seconds(15)])
    }

    func testRateLimitGivesUpAfterTheLastWait() async {
        let transcriber = MeetingTranscriber(primary: ScriptedSpeech([.failure(.http(429))]), retryDelays: [.seconds(1)], sleep: { _ in })
        do { _ = try await transcriber.text(for: chunk); XCTFail("expected an error") }
        catch { XCTAssertEqual(error.localizedDescription, CloudError.http(429).localizedDescription) }
    }

    func testOtherErrorsFallBackOrSurface() async throws {
        let withLocal = MeetingTranscriber(primary: ScriptedSpeech([.failure(.http(500))]), fallback: ScriptedSpeech([.success("ok")]))
        let text = try await withLocal.text(for: chunk)
        XCTAssertEqual(text, "ok")
        let alone = MeetingTranscriber(primary: ScriptedSpeech([.failure(.http(401))]))
        do { _ = try await alone.text(for: chunk); XCTFail("expected an error") } catch {}
    }

    func testEmptyRecognitionIsNotAnError() async throws {
        let transcriber = MeetingTranscriber(primary: ScriptedSpeech([.failure(.invalidResponse)]))
        let text = try await transcriber.text(for: chunk)
        XCTAssertNil(text)
    }
}

// MARK: Assistant

final class MeetingAssistantTests: XCTestCase {
    private let meeting = Meeting(id: "m", title: "Launch planning", started: Date(timeIntervalSince1970: 1_700_000_000),
                                  notes: "ask about pricing page")
    private let lines = [segment(5, .me, "When does the launch move?"), segment(12, .them, "To the fourteenth of March."),
                         segment(75, .them, "Priya owns the pricing page.")]

    func testTranscriptFormat() {
        XCTAssertEqual(MeetingAssistant.transcript(lines),
                       "[00:05] Me: When does the launch move?\n[00:12] Them: To the fourteenth of March.\n[01:15] Them: Priya owns the pricing page.")
        XCTAssertEqual(MeetingAssistant.stamp(3_725), "1:02:05")
        XCTAssertEqual(MeetingAssistant.seconds("01:15"), 75); XCTAssertEqual(MeetingAssistant.seconds("1:02:05"), 3_725)
        XCTAssertNil(MeetingAssistant.seconds("abc"))
    }

    func testPartsSplitOnLinesAndEarlierPartsStayTheSame() {
        let many = (0..<40).map { segment(Double($0 * 10), .them, String(repeating: "word ", count: 20)) }
        let parts = MeetingAssistant.parts(many, limit: 1_000)
        XCTAssertGreaterThan(parts.count, 3)
        for part in parts { XCTAssertLessThanOrEqual(part.count, 1_000) }
        XCTAssertEqual(parts.joined(separator: "\n"), MeetingAssistant.transcript(many), "nothing is lost")
        let grown = MeetingAssistant.parts(many + [segment(900, .me, "one more line")], limit: 1_000)
        XCTAssertEqual(Array(grown.prefix(parts.count - 1)), Array(parts.dropLast()))
    }

    func testShortMeetingIsOneRequestWithNotesTemplateAndTranscript() async throws {
        let chat = ScriptedChat("## Summary\n- Launch moves to 14 March [00:12]")
        let notes = try await MeetingAssistant(provider: chat).notes(meeting: meeting, segments: lines, template: .general)
        XCTAssertEqual(notes, "## Summary\n- Launch moves to 14 March [00:12]")
        let requests = await chat.requests
        XCTAssertEqual(requests.count, 1)
        let sent = try XCTUnwrap(requests.first?.turns.first?.text)
        for expected in ["Launch planning", "<my_notes>\nask about pricing page\n</my_notes>", "Action items",
                         "<transcript>\n[00:05] Me: When does the launch move?", "Priya owns the pricing page."] {
            XCTAssertTrue(sent.contains(expected), expected)
        }
        XCTAssertEqual(requests.first?.system, MeetingAssistant.notesSystem)
    }

    func testLongMeetingIsCondensedInPartsAndReusesKnownSummaries() async throws {
        let many = (0..<30).map { segment(Double($0 * 20), .them, "Topic \($0) " + String(repeating: "detail ", count: 30)) }
        var assistant = MeetingAssistant(provider: ScriptedChat("unused"))
        assistant.partLimit = 2_000
        let parts = MeetingAssistant.parts(many, limit: 2_000)
        XCTAssertGreaterThan(parts.count, 2)
        let chat = ScriptedChat([.success("- part summary [00:20]"), .success("- part summary [00:20]"), .success("## Summary\n- merged")])
        assistant = MeetingAssistant(provider: chat, partLimit: 2_000)
        let known = Dictionary(uniqueKeysWithValues: parts.dropLast(2).map { ($0, "- known summary") })
        let notes = try await assistant.notes(meeting: meeting, segments: many, template: .general, summaries: known)
        XCTAssertEqual(notes, "## Summary\n- merged")
        let requests = await chat.requests
        XCTAssertEqual(requests.count, 3, "two unknown parts, then the merge")
        XCTAssertEqual(requests[0].system, MeetingAssistant.partSystem)
        let merge = try XCTUnwrap(requests.last?.turns.first?.text)
        XCTAssertTrue(merge.contains("<condensed_transcript>")); XCTAssertTrue(merge.contains("- known summary"))
        XCTAssertTrue(merge.contains("- part summary")); XCTAssertFalse(merge.contains("detail detail"))
    }

    func testEmptyTranscriptIsRefusedWithoutARequest() async {
        let chat = ScriptedChat("x")
        do { _ = try await MeetingAssistant(provider: chat).notes(meeting: meeting, segments: [], template: .general); XCTFail() }
        catch { XCTAssertEqual(error.localizedDescription, MeetingError.emptyTranscript.localizedDescription) }
        let count = await chat.requests.count
        XCTAssertEqual(count, 0)
    }

    func testTimesPastTheEndOfTheMeetingAreRemoved() {
        let notes = "- Real point [01:15]\n- Invented point [45:00]\n- Hour mark [1:10:00]\n- Close to the end [01:40]"
        XCTAssertEqual(MeetingAssistant.removingUnknownTimes(notes, lastStart: 75),
                       "- Real point [01:15]\n- Invented point\n- Hour mark\n- Close to the end [01:40]")
    }

    func testTimeRangesBecomeTheirStartTime() {
        XCTAssertEqual(MeetingAssistant.singleTimes("- A [00:05‑00:08]\n- B [1:02:03 - 1:02:30]\n- C [00:19–00:26] and [00:43]\n- D 【0:53】"),
                       "- A [00:05]\n- B [1:02:03]\n- C [00:19] and [00:43]\n- D [0:53]")
    }

    func testRateLimitIsWaitedOutThenFails() async throws {
        let waits = Waits()
        let chat = ScriptedChat([.failure(.http(429)), .success("notes")])
        let assistant = MeetingAssistant(provider: chat, sleep: { await waits.add($0) })
        let notes = try await assistant.notes(meeting: meeting, segments: lines, template: .general)
        let taken = await waits.taken
        XCTAssertEqual(notes, "notes"); XCTAssertEqual(taken, [.seconds(15)])
        let never = MeetingAssistant(provider: ScriptedChat([.failure(.http(429))]), retryDelays: [], sleep: { _ in })
        do { _ = try await never.notes(meeting: meeting, segments: lines, template: .general); XCTFail() } catch {}
    }

    func testAnswerSendsOnlyThisMeetingAndRecentHistory() async throws {
        let chat = ScriptedChat("14 March [00:12]")
        let history = (0..<8).map { ChatTurn(fromUser: $0 % 2 == 0, text: "turn \($0)") }
        let answer = try await MeetingAssistant(provider: chat).answer(question: "When is launch?", meeting: meeting, segments: lines, history: history)
        XCTAssertEqual(answer, "14 March [00:12]")
        let found1 = await chat.requests.first
        let request = try XCTUnwrap(found1)
        XCTAssertEqual(request.system, MeetingAssistant.answerSystem)
        XCTAssertTrue(request.system.contains(MeetingAssistant.notDiscussed))
        XCTAssertEqual(request.turns.count, 5); XCTAssertEqual(request.turns.first?.text, "turn 4")
        let sent = try XCTUnwrap(request.turns.last?.text)
        XCTAssertTrue(sent.contains("[00:12] Them: To the fourteenth of March.")); XCTAssertTrue(sent.hasSuffix("Question: When is launch?"))
    }

    func testLongMeetingMaterialKeepsMatchingLinesAndTheRecentPart() {
        var many = (0..<200).map { segment(Double($0 * 10), .them, "Filler conversation number \($0) " + String(repeating: "blah ", count: 12)) }
        many[20] = segment(200, .them, "The Zanzibar contract renews in June")
        var noted = meeting; noted.enhanced = "## Summary\n- A long meeting"
        let material = MeetingAssistant.material(question: "When does the Zanzibar contract renew?", meeting: noted, segments: many, limit: 3_000)
        XCTAssertLessThan(material.count, 3_600)
        XCTAssertTrue(material.contains("Zanzibar contract renews in June")); XCTAssertTrue(material.contains("number 199"))
        XCTAssertTrue(material.contains("<meeting_notes>")); XCTAssertTrue(material.contains("<transcript_excerpts>"))
        XCTAssertFalse(material.contains("number 100 "))
    }

    func testKeywordsDropFillerWords() {
        XCTAssertEqual(MeetingAssistant.keywords("What did they say about the Zanzibar pricing?"), ["zanzibar", "pricing"])
    }

    func testAcrossMeetingsNamesEachMeeting() async throws {
        let first = Meeting(id: "a", title: "Budget", started: Date(timeIntervalSince1970: 1_700_000_000), enhanced: "- Budget is 40k")
        let second = Meeting(id: "b", title: "Hiring", started: Date(timeIntervalSince1970: 1_700_100_000), notes: "need two engineers")
        let material = MeetingAssistant.acrossMaterial(meetings: [first, second], hits: [segment(65, .me, "I'll send the offer Monday", meeting: "b")], limit: 4_000)
        XCTAssertTrue(material.contains("<meeting title=\"Budget (")); XCTAssertTrue(material.contains("- Budget is 40k"))
        XCTAssertTrue(material.contains("need two engineers"))
        XCTAssertTrue(material.contains(") [01:05] Me: I'll send the offer Monday"))
        XCTAssertLessThan(try XCTUnwrap(material.range(of: "Hiring")).lowerBound, try XCTUnwrap(material.range(of: "Budget")).lowerBound, "newest first")
        let chat = ScriptedChat("x")
        let empty = try await MeetingAssistant(provider: chat).answerAcross(question: "q", meetings: [], hits: [])
        let count = await chat.requests.count
        XCTAssertEqual(empty, "That doesn't appear in your meetings."); XCTAssertEqual(count, 0)
    }

    func testGroqChatRequestCarriesTheConversation() async throws {
        let transport = FixtureTransport(#"{"choices":[{"message":{"content":"Answer."},"finish_reason":"stop"}]}"#)
        let provider = GroqCleanupProvider(timeout: 60, authorize: { "unit-test-key" }, transport: transport)
        let reply = try await provider.reply(system: "sys", turns: [.init(fromUser: true, text: "q1"), .init(fromUser: false, text: "a1"),
                                                                     .init(fromUser: true, text: "q2")], maxTokens: 900)
        XCTAssertEqual(reply, "Answer.")
        let found2 = await transport.requests.first
        let request = try XCTUnwrap(found2)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
        let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
        XCTAssertEqual(messages.map { $0["role"] }, ["system", "user", "assistant", "user"])
        XCTAssertEqual(messages.last?["content"], "q2"); XCTAssertEqual(body["max_completion_tokens"] as? Int, 900)
        XCTAssertEqual(request.timeoutInterval, 60)
    }
}

// MARK: Templates, recipes, export

@MainActor
final class MeetingFeatureTests: XCTestCase {
    private func settings() -> MeetingSettings { MeetingSettings(defaults: UserDefaults(suiteName: "utter-tests-\(UUID().uuidString)")!) }

    func testRecipesMatchByNameAndScope() {
        let recipes = MeetingRecipe.builtIn
        XCTAssertEqual(MeetingRecipe.match("/Action items", in: recipes, scope: .single)?.id, "actions")
        XCTAssertEqual(MeetingRecipe.match("/follow", in: recipes, scope: .single)?.id, "follow-up")
        XCTAssertNil(MeetingRecipe.match("/action items", in: recipes, scope: .all), "single-meeting recipes do not run across meetings")
        XCTAssertEqual(MeetingRecipe.match("/what did", in: recipes, scope: .all)?.id, "promises")
        XCTAssertNil(MeetingRecipe.match("action items", in: recipes, scope: .single)); XCTAssertNil(MeetingRecipe.match("/", in: recipes, scope: .single))
    }

    func testCustomTemplatesAndRecipesPersist() {
        let suite = "utter-tests-\(UUID().uuidString)"
        let first = MeetingSettings(defaults: UserDefaults(suiteName: suite)!)
        XCTAssertEqual(first.templates.map(\.id), ["general", "one-on-one", "stand-up", "sales-call", "interview"])
        XCTAssertTrue(first.detectMeetings); XCTAssertFalse(first.consentAcknowledged)
        first.customTemplates.append(MeetingTemplate(id: "mine", name: "Client call", instructions: "Sections: Wins"))
        first.customRecipes.append(MeetingRecipe(id: "r", name: "Risks", scope: .single, prompt: "List risks"))
        first.defaultTemplate = "mine"; first.detectMeetings = false
        let second = MeetingSettings(defaults: UserDefaults(suiteName: suite)!)
        XCTAssertEqual(second.template(id: "mine").name, "Client call"); XCTAssertEqual(second.recipes.last?.prompt, "List risks")
        XCTAssertEqual(second.defaultTemplate, "mine"); XCTAssertFalse(second.detectMeetings)
        XCTAssertEqual(second.template(id: "deleted"), .general, "an unknown template falls back to General")
    }

    func testMarkdownExport() {
        let meeting = Meeting(id: "m", title: "Launch planning", started: Date(timeIntervalSince1970: 1_700_000_000),
                              notes: "ask about pricing", enhanced: "## Summary\n- Launch moves [00:12]")
        let lines = [segment(5, .me, "When?"), segment(12, .them, "March.")]
        let full = MeetingsController.markdown(meeting: meeting, segments: lines, transcript: true)
        let date = meeting.started.formatted(date: .long, time: .shortened)
        XCTAssertEqual(full, "# Launch planning\n\n\(date)\n\n## Summary\n- Launch moves [00:12]\n\n## My notes\n\nask about pricing\n\n## Transcript\n\n[00:05] Me: When?\n[00:12] Them: March.\n")
        XCTAssertFalse(MeetingsController.markdown(meeting: meeting, segments: lines, transcript: false).contains("Transcript"))
    }

    func testTimesInNotesBecomeLinks() {
        let text = MeetingMarkdown.inline("Launch **moves** [01:15] and [not a time]")
        let links = text.runs.compactMap(\.link)
        XCTAssertEqual(links.map(\.absoluteString), ["utter-time://75"])
        XCTAssertEqual(String(text.characters), "Launch moves 01:15 and [not a time]")
        XCTAssertEqual(MeetingMarkdown.bullet("- [ ] Send deck")?.marker, "☐"); XCTAssertEqual(MeetingMarkdown.bullet("2. Second")?.text, "Second")
        XCTAssertNil(MeetingMarkdown.bullet("Plain line"))
    }

    func testSettingsPageRenders() {
        let view = MeetingSettingsView(settings: settings()) {}
        XCTAssertGreaterThan(NSHostingView(rootView: view).fittingSize.height, 0)
    }
}

// MARK: Detection

final class MeetingDetectionTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000)
    private func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

    func testOffersOnceAfterTheMicrophoneIsHeld() {
        var detection = MeetingDetection()
        XCTAssertNil(detection.update(callApps: ["Google Chrome"], recording: false, now: at(0)))
        XCTAssertNil(detection.update(callApps: ["Google Chrome"], recording: false, now: at(3)))
        XCTAssertEqual(detection.update(callApps: ["Google Chrome"], recording: false, now: at(4)), .offer(app: "Google Chrome"))
        for second in stride(from: 5.0, to: 600, by: 5) {
            XCTAssertNil(detection.update(callApps: ["Google Chrome"], recording: false, now: at(second)), "one offer per call")
        }
    }

    func testBriefMicrophoneUseDoesNotOffer() {
        var detection = MeetingDetection()
        XCTAssertNil(detection.update(callApps: ["Safari"], recording: false, now: at(0)))
        XCTAssertNil(detection.update(callApps: ["Safari"], recording: false, now: at(2)))
        for second in stride(from: 3.0, to: 40, by: 1) { XCTAssertNil(detection.update(callApps: [], recording: false, now: at(second))) }
    }

    func testANewCallOffersAgainButAShortDropoutDoesNot() {
        var detection = MeetingDetection()
        _ = detection.update(callApps: ["Zoom"], recording: false, now: at(0))
        XCTAssertNotNil(detection.update(callApps: ["Zoom"], recording: false, now: at(5)))
        XCTAssertNil(detection.update(callApps: [], recording: false, now: at(8)))
        XCTAssertNil(detection.update(callApps: ["Zoom"], recording: false, now: at(10)), "same call after a dropout")
        XCTAssertNil(detection.update(callApps: ["Zoom"], recording: false, now: at(20)))
        XCTAssertNil(detection.update(callApps: [], recording: false, now: at(21)))
        XCTAssertNil(detection.update(callApps: [], recording: false, now: at(40)))
        XCTAssertNil(detection.update(callApps: ["Zoom"], recording: false, now: at(50)))
        XCTAssertEqual(detection.update(callApps: ["Zoom"], recording: false, now: at(55)), .offer(app: "Zoom"))
    }

    func testNoOfferWhileRecordingAndCallEndStopsIt() {
        var detection = MeetingDetection()
        for second in stride(from: 0.0, to: 30, by: 1) {
            XCTAssertNil(detection.update(callApps: ["Google Chrome"], recording: true, now: at(second)))
        }
        XCTAssertNil(detection.update(callApps: [], recording: true, now: at(35)), "a pause shorter than the release time")
        XCTAssertEqual(detection.update(callApps: [], recording: true, now: at(42)), .callEnded)
        XCTAssertNil(detection.update(callApps: [], recording: true, now: at(60)), "reported once")
    }

    func testRecordingWithoutACallNeverReportsCallEnded() {
        var detection = MeetingDetection()
        for second in stride(from: 0.0, to: 120, by: 2) { XCTAssertNil(detection.update(callApps: [], recording: true, now: at(second))) }
    }

    func testACallThatEndedBeforeRecordingStartedDoesNotStopTheNextRecording() {
        var detection = MeetingDetection()
        _ = detection.update(callApps: ["Zoom"], recording: false, now: at(0))
        _ = detection.update(callApps: ["Zoom"], recording: false, now: at(5))
        XCTAssertNil(detection.update(callApps: [], recording: true, now: at(6)))
        XCTAssertNil(detection.update(callApps: [], recording: true, now: at(30)))
    }

    func testCallAppsAreRecognisedByBundlePrefix() {
        XCTAssertEqual(CallApps.name(for: "com.google.Chrome.helper"), "Google Chrome")
        XCTAssertEqual(CallApps.name(for: "us.zoom.xos"), "Zoom"); XCTAssertEqual(CallApps.name(for: "com.microsoft.teams2"), "Microsoft Teams")
        XCTAssertNil(CallApps.name(for: "org.utter.app")); XCTAssertNil(CallApps.name(for: "com.apple.Music"))
    }
}

// MARK: Controller

@MainActor
final class MeetingsControllerTests: XCTestCase {
    private var capture: FakeCapture!
    private var store: MeetingStore!
    private var controller: MeetingsController!
    private var chat: ScriptedChat!
    private var clock = Date(timeIntervalSince1970: 1_700_000_000)

    private func make(speech: any TranscriptionProvider, chat: ScriptedChat = ScriptedChat("## Summary\n- Notes [00:05]")) {
        capture = FakeCapture(); store = temporaryStore(); self.chat = chat
        let settings = MeetingSettings(defaults: UserDefaults(suiteName: "utter-tests-\(UUID().uuidString)")!)
        settings.consentAcknowledged = true
        controller = MeetingsController(settings: settings, store: store, capture: capture)
        controller.makeTranscriber = { MeetingTranscriber(primary: speech) }
        controller.makeAssistant = { MeetingAssistant(provider: chat) }
        controller.microphoneUID = { "mic-1" }
        controller.now = { [unowned self] in self.clock }
    }

    private func wait(_ what: String, timeout: TimeInterval = 5, _ condition: @MainActor () async throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for \(what)")
    }

    func testRecordingBuildsATranscriptInSpokenOrderThenWritesNotes() async throws {
        // The first chunk is slow, so its text arrives after the second chunk's.
        make(speech: TimedSpeech(texts: [1: "When does the launch move?", 2: "To the fourteenth of March."], delays: [1: .milliseconds(150)]))
        controller.start()
        XCTAssertTrue(controller.isRecording)
        XCTAssertEqual(capture.started.first?.uid, "mic-1"); XCTAssertEqual(capture.started.first?.offset, 0)
        try await wait("selection") { self.controller.selected != nil }
        let id = try XCTUnwrap(controller.recordingID)
        capture.say(.me, at: 5, key: 1)
        capture.say(.them, at: 12, key: 2)
        try await wait("both lines") { self.controller.segments.count == 2 }
        XCTAssertEqual(controller.segments.map(\.text), ["When does the launch move?", "To the fourteenth of March."])
        XCTAssertEqual(controller.segments.map(\.speaker), [.me, .them])
        controller.setNotes("ask about pricing")
        clock = clock.addingTimeInterval(600)
        controller.stop()
        XCTAssertFalse(controller.isRecording); XCTAssertEqual(capture.stops, 1)
        try await wait("enhanced notes") { try await self.store.meeting(id: id)?.enhanced == "## Summary\n- Notes [00:05]" }
        let found3 = try await store.meeting(id: id)
        let saved = try XCTUnwrap(found3)
        XCTAssertEqual(saved.notes, "ask about pricing", "the user's own notes are kept beside the enhanced ones")
        XCTAssertEqual(saved.ended, clock)
        let found4 = await chat.requests.first?.turns.first?.text
        let sent = try XCTUnwrap(found4)
        XCTAssertTrue(sent.contains("ask about pricing")); XCTAssertTrue(sent.contains("[00:12] Them: To the fourteenth of March."))
    }

    func testSpeechStillBeingTranscribedAtStopIsKept() async throws {
        make(speech: TimedSpeech(texts: [1: "Last words before hanging up"], delays: [1: .milliseconds(200)]))
        controller.start()
        let id = try XCTUnwrap(controller.recordingID)
        capture.say(.them, at: 30, key: 1)
        controller.stop()
        try await wait("notes after the late line") { try await self.store.meeting(id: id)?.enhanced.isEmpty == false }
        let lines = try await store.segments(meeting: id)
        XCTAssertEqual(lines.map(\.text), ["Last words before hanging up"])
    }

    func testMicrophoneEchoOfTheCallIsKeptOnlyAsThem() async throws {
        make(speech: TimedSpeech(texts: [1: "The launch is moving to the fourteenth of March", 2: "the launch is moving to the fourteenth of march",
                                         3: "I will update the pricing page on Tuesday", 4: "we should also brief the sales team first",
                                         5: "We should also brief the sales team first"],
                                 delays: [5: .milliseconds(120)]))
        controller.start()
        let id = try XCTUnwrap(controller.recordingID)
        capture.say(.them, at: 10, key: 1)
        try await wait("first line") { try await self.store.segments(meeting: id).count == 1 }
        capture.say(.me, at: 10.4, key: 2)       // loudspeaker picked up by the microphone
        capture.say(.me, at: 16, key: 3)         // the user's own reply
        capture.say(.me, at: 30.5, key: 4)       // echo that is transcribed before the original
        capture.say(.them, at: 30, key: 5)
        try await wait("all chunks handled") { self.controller.pendingChunks == 0 }
        let lines = try await store.segments(meeting: id)
        XCTAssertEqual(lines.map(\.speaker), [.them, .me, .them])
        XCTAssertEqual(lines.map(\.text), ["The launch is moving to the fourteenth of March", "I will update the pricing page on Tuesday",
                                           "We should also brief the sales team first"])
        XCTAssertEqual(controller.segments, lines)
    }

    func testNotesFailureLeavesEverythingElseIntact() async throws {
        make(speech: TimedSpeech(texts: [1: "Hello there everyone"]), chat: ScriptedChat([.failure(.http(500))]))
        controller.start()
        let id = try XCTUnwrap(controller.recordingID)
        try await wait("selection") { self.controller.selected != nil }
        controller.setNotes("my own notes")
        capture.say(.them, at: 1, key: 1)
        try await wait("line") { self.controller.segments.count == 1 }
        controller.stop()
        try await wait("failure message") { self.controller.message?.contains("could not be written") == true }
        let found5 = try await store.meeting(id: id)
        let saved = try XCTUnwrap(found5)
        let count = try await store.segments(meeting: id).count
        XCTAssertEqual(saved.enhanced, ""); XCTAssertEqual(saved.notes, "my own notes"); XCTAssertEqual(count, 1)
        XCTAssertNil(controller.enhancingID, "Rewrite can be tried again")
    }

    func testTranscriptionFailureIsReportedAndRecordingContinues() async throws {
        make(speech: ScriptedSpeech([.failure(.http(401)), .success("Second chunk worked")]))
        controller.start()
        capture.say(.them, at: 1, key: 1)
        try await wait("error") { self.controller.message?.contains("could not be transcribed") == true }
        XCTAssertTrue(controller.isRecording)
        capture.say(.them, at: 9, key: 2)
        try await wait("next line") { self.controller.segments.map(\.text) == ["Second chunk worked"] }
    }

    func testStartFailureDoesNotCreateAMeeting() async throws {
        make(speech: TimedSpeech(texts: [:]))
        capture.startError = RecordingError.message("No microphone.")
        controller.start()
        XCTAssertFalse(controller.isRecording); XCTAssertEqual(controller.message, "No microphone.")
        controller.makeTranscriber = { throw CloudError.missingKey(.groq) }
        capture.startError = nil
        controller.start()
        XCTAssertFalse(controller.isRecording); XCTAssertTrue(capture.started.isEmpty)
        let count = try await store.meetings().count
        XCTAssertEqual(count, 0)
    }

    func testOnlyOneMeetingRecordsAtATime() {
        make(speech: TimedSpeech(texts: [:]))
        controller.start()
        let first = controller.recordingID
        controller.start()
        XCTAssertEqual(controller.recordingID, first); XCTAssertEqual(capture.started.count, 1)
        XCTAssertEqual(controller.message, MeetingError.alreadyRecording.localizedDescription)
    }

    func testLongSilenceStopsTheRecording() async throws {
        make(speech: TimedSpeech(texts: [1: "Some speech"]))
        controller.start()
        capture.say(.them, at: 1, key: 1)
        clock = clock.addingTimeInterval(14 * 60)
        controller.checkRecording()
        XCTAssertTrue(controller.isRecording)
        clock = clock.addingTimeInterval(61)
        controller.checkRecording()
        XCTAssertFalse(controller.isRecording); XCTAssertEqual(capture.stops, 1)
        XCTAssertEqual(controller.message, "Stopped the meeting after 15 minutes of silence.")
    }

    func testSilentSystemAudioExplainsThePermission() {
        make(speech: TimedSpeech(texts: [:]))
        capture.heardSystemAudio = false
        controller.start()
        clock = clock.addingTimeInterval(30); controller.checkRecording()
        XCTAssertNil(controller.message)
        clock = clock.addingTimeInterval(20); controller.checkRecording()
        XCTAssertEqual(controller.message, MeetingError.systemAudioDenied.localizedDescription)
        XCTAssertTrue(controller.isRecording, "the microphone side keeps recording")
    }

    func testDictationPausesTheMeetingMicrophone() {
        make(speech: TimedSpeech(texts: [:]))
        controller.setDictating(true); XCTAssertTrue(capture.microphonePaused)
        controller.setDictating(false); XCTAssertFalse(capture.microphonePaused)
    }

    func testResumeAppendsAfterTheEarlierRecording() async throws {
        make(speech: TimedSpeech(texts: [1: "First half", 2: "Second half"]))
        controller.start()
        let id = try XCTUnwrap(controller.recordingID)
        capture.say(.them, at: 10, key: 1)
        try await wait("first line") { self.controller.segments.count == 1 }
        clock = clock.addingTimeInterval(300)
        controller.stop(enhance: false)
        try await wait("ended") { try await self.store.meeting(id: id)?.ended != nil }
        let found6 = try await store.meeting(id: id)
        let meeting = try XCTUnwrap(found6)
        clock = clock.addingTimeInterval(3_600)
        controller.start(resuming: meeting)
        XCTAssertEqual(controller.recordingID, id)
        XCTAssertEqual(try XCTUnwrap(capture.started.last).offset, 300, accuracy: 0.01, "continues from the earlier length, not the wall clock")
        capture.say(.them, at: 305, key: 2)
        try await wait("both lines") { self.controller.segments.map(\.text) == ["First half", "Second half"] }
        let count = try await store.meetings().count
        XCTAssertEqual(count, 1)
    }

    func testConsentIsAskedOnceAndCanCancel() {
        make(speech: TimedSpeech(texts: [:]))
        controller.settings.consentAcknowledged = false
        var asked = 0
        controller.confirmConsent = { asked += 1; return false }
        controller.start()
        XCTAssertFalse(controller.isRecording); XCTAssertFalse(controller.settings.consentAcknowledged)
        controller.confirmConsent = { asked += 1; return true }
        controller.start()
        XCTAssertTrue(controller.isRecording); XCTAssertTrue(controller.settings.consentAcknowledged)
        controller.stop(enhance: false)
        controller.start()
        XCTAssertEqual(asked, 2)
    }

    func testAskingAboutAMeetingSavesTheConversationAndRunsRecipes() async throws {
        make(speech: TimedSpeech(texts: [1: "Priya owns the pricing page"]), chat: ScriptedChat("Priya [00:01]"))
        controller.start()
        let id = try XCTUnwrap(controller.recordingID)
        try await wait("selection") { self.controller.selected != nil }
        capture.say(.them, at: 1, key: 1)
        try await wait("line") { self.controller.segments.count == 1 }
        controller.ask("Who owns the pricing page?")     // works while the meeting is still running
        try await wait("answer") { self.controller.chat.count == 2 && !self.controller.answering }
        XCTAssertEqual(controller.chat.map(\.text), ["Who owns the pricing page?", "Priya [00:01]"])
        controller.ask("/action items")
        try await wait("recipe answer") { self.controller.chat.count == 4 && !self.controller.answering }
        XCTAssertEqual(controller.chat[2].text, "/Action items")
        let requests = await chat.requests
        XCTAssertTrue(try XCTUnwrap(requests.last?.turns.last?.text).contains("List every action item"))
        XCTAssertTrue(try XCTUnwrap(requests.last?.turns.last?.text).contains("Priya owns the pricing page"))
        let saved = try await store.chat(meeting: id).count
        XCTAssertEqual(saved, 4)
        controller.stop(enhance: false)
    }

    func testAskingAcrossMeetingsUsesNotesAndMatchingLines() async throws {
        make(speech: TimedSpeech(texts: [:]), chat: ScriptedChat("You promised the offer (Hiring)."))
        try await store.save(Meeting(id: "a", title: "Hiring", started: clock, enhanced: "- Need two engineers"))
        try await store.save(Meeting(id: "b", title: "Budget", started: clock.addingTimeInterval(-86_400), enhanced: "- Budget is 40k"))
        try await store.add(segment(65, .me, "I'll send the offer on Monday", meeting: "a"))
        controller.ask("What did I say about the offer?", overall: true)
        try await wait("answer") { self.controller.overallChat.count == 2 }
        XCTAssertEqual(controller.overallChat.last?.text, "You promised the offer (Hiring).")
        let found7 = await chat.requests.first
        let request = try XCTUnwrap(found7)
        XCTAssertEqual(request.system, MeetingAssistant.acrossSystem)
        let sent = try XCTUnwrap(request.turns.first?.text)
        for expected in ["Need two engineers", "Budget is 40k", "I'll send the offer on Monday"] { XCTAssertTrue(sent.contains(expected), expected) }
    }

    func testChatFailureIsShownAsAReply() async throws {
        make(speech: TimedSpeech(texts: [:]), chat: ScriptedChat([.failure(.http(401))]))
        try await store.save(Meeting(id: "a", title: "Hiring", started: clock, enhanced: "- Notes"))
        controller.ask("anything?", overall: true)
        try await wait("reply") { self.controller.overallChat.count == 2 }
        XCTAssertTrue(try XCTUnwrap(controller.overallChat.last?.text).hasPrefix("Couldn't answer:"))
        XCTAssertFalse(controller.answering)
    }

    func testDeletingAMeetingAndALine() async throws {
        make(speech: TimedSpeech(texts: [1: "Keep this", 2: "Remove this"]))
        controller.start()
        let id = try XCTUnwrap(controller.recordingID)
        capture.say(.them, at: 1, key: 1); capture.say(.them, at: 9, key: 2)
        try await wait("lines") { self.controller.segments.count == 2 }
        controller.delete(segment: try XCTUnwrap(controller.segments.last))
        try await wait("line removed") { self.controller.segments.map(\.text) == ["Keep this"] }
        let left = try await store.segments(meeting: id).count
        XCTAssertEqual(left, 1)
        controller.delete(id)
        XCTAssertFalse(controller.isRecording, "deleting the meeting being recorded stops it")
        try await wait("meeting removed") { try await self.store.meetings().isEmpty }
        try await wait("selection cleared") { self.controller.selectedID == nil }
    }

    func testChoosingATemplateRewritesNotesWithIt() async throws {
        make(speech: TimedSpeech(texts: [:]), chat: ScriptedChat("## Done\n- Shipped"))
        try await store.save(Meeting(id: "a", title: "Daily", started: clock))
        try await store.add(segment(3, .them, "I shipped the importer", meeting: "a"))
        controller.enhance("a", template: "stand-up")
        try await wait("notes") { try await self.store.meeting(id: "a")?.enhanced == "## Done\n- Shipped" }
        let template = try await store.meeting(id: "a")?.template
        XCTAssertEqual(template, "stand-up")
        let found8 = await chat.requests.first?.turns.first?.text
        let sent = try XCTUnwrap(found8)
        XCTAssertTrue(sent.contains("\"Blockers\""))
    }
}
