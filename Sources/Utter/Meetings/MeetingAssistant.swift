import Foundation

struct ChatTurn: Sendable, Equatable {
    let fromUser: Bool
    let text: String
}

/// A chat model that writes meeting notes and answers questions.
protocol ChatProvider: Sendable {
    func reply(system: String, turns: [ChatTurn], maxTokens: Int) async throws -> String
}

/// Writes enhanced notes and answers questions from a meeting's transcript.
///
/// Groq's free tier allows about 8,000 tokens a minute per model, so a long transcript is summarised
/// in parts and the parts are then merged, waiting out the per-minute allowance when needed.
struct MeetingAssistant: Sendable {
    let provider: any ChatProvider
    /// Characters of transcript sent in one request (about four characters per token).
    var partLimit = 12_000
    /// Waits tried, in order, when the provider says its per-minute allowance is used up.
    var retryDelays: [Duration] = [.seconds(15), .seconds(25), .seconds(35)]
    var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }

    static let notDiscussed = "That wasn't discussed in this meeting."
    /// Chosen for accuracy over speed: in live checks the faster cleanup model misspelled a place name in a short answer.
    static let defaultModel = "openai/gpt-oss-120b"

    // MARK: Transcript text

    static func stamp(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return total >= 3600 ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
                             : String(format: "%02d:%02d", total / 60, total % 60)
    }

    static func line(_ segment: TranscriptSegment) -> String {
        "[\(stamp(segment.start))] \(segment.speaker.title): \(segment.text)"
    }

    static func transcript(_ segments: [TranscriptSegment]) -> String {
        segments.map(line).joined(separator: "\n")
    }

    /// Splits the transcript into pieces of at most `limit` characters, on line boundaries.
    /// Earlier pieces do not change as the meeting grows, so their summaries can be reused.
    static func parts(_ segments: [TranscriptSegment], limit: Int) -> [String] {
        var result: [String] = []
        var current = ""
        for text in segments.map(line) {
            if !current.isEmpty && current.count + text.count + 1 > limit {
                result.append(current)
                current = ""
            }
            current += current.isEmpty ? text : "\n" + text
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    // MARK: Notes

    static let notesSystem = """
    You write meeting notes from a transcript. "Me" is the person these notes are for; "Them" is everyone else on the call.
    Rules:
    - Use only what is in the transcript and the user's own notes. Never invent names, numbers, dates or decisions.
    - The user's own notes show what they cared about: keep every point they wrote and expand it with detail from the transcript.
    - Write Markdown: "## " section headings and "- " bullets. No preamble, no closing remarks.
    - End each bullet with the one time it was first discussed, copied from the transcript, like [12:34]. Never a range of times.
    - Write "I" for Me and "they" for Them, or a person's name when the transcript gives it. Copy names and places exactly as the transcript spells them.
    - Leave a section out if nothing was said for it.
    """

    static let partSystem = """
    You condense one part of a meeting transcript. "Me" is the note-taker; "Them" is everyone else.
    Write detailed "- " bullets covering every topic, fact, number, decision, question and commitment, saying who said it.
    End each bullet with the time from the transcript, like [12:34]. Use only what is in the transcript. No preamble.
    """

    static func partRequest(_ part: String) -> String { "<transcript_part>\n\(part)\n</transcript_part>" }

    static func notesRequest(meeting: Meeting, template: MeetingTemplate, material: String, condensed: Bool) -> String {
        var text = "Meeting title: \(meeting.title)\nDate: \(meeting.started.formatted(date: .abbreviated, time: .shortened))\n\n"
        text += "Layout to follow:\n\(template.instructions)\n\n"
        let notes = meeting.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty { text += "<my_notes>\n\(notes)\n</my_notes>\n\n" }
        text += condensed ? "<condensed_transcript>\n\(material)\n</condensed_transcript>" : "<transcript>\n\(material)\n</transcript>"
        return text
    }

    /// Condenses one part of a transcript. Called while a meeting runs so little is left to do when it ends.
    func summary(ofPart part: String) async throws -> String {
        try await ask(system: Self.partSystem, turns: [ChatTurn(fromUser: true, text: Self.partRequest(part))], maxTokens: 900)
    }

    /// Enhanced notes for a meeting. `summaries` holds part summaries already made, keyed by the part's text.
    func notes(meeting: Meeting, segments: [TranscriptSegment], template: MeetingTemplate,
               summaries: [String: String] = [:]) async throws -> String {
        guard !segments.isEmpty else { throw MeetingError.emptyTranscript }
        let parts = Self.parts(segments, limit: partLimit)
        let material: String
        if parts.count == 1 {
            material = parts[0]
        } else {
            var condensed: [String] = []
            for part in parts {
                if let known = summaries[part] { condensed.append(known) }
                else { condensed.append(try await summary(ofPart: part)) }
            }
            material = condensed.joined(separator: "\n")
        }
        let request = Self.notesRequest(meeting: meeting, template: template, material: String(material.prefix(partLimit * 2)),
                                        condensed: parts.count > 1)
        let written = try await ask(system: Self.notesSystem, turns: [ChatTurn(fromUser: true, text: request)], maxTokens: 1500)
        return Self.removingUnknownTimes(written, lastStart: segments.map(\.start).max() ?? 0)
    }

    /// Models sometimes cite a span such as [00:05-00:08], or use 【full-width】 brackets;
    /// keep one plain time so every citation can link to the transcript.
    static func singleTimes(_ notes: String) -> String {
        notes.replacingOccurrences(of: "【", with: "[").replacingOccurrences(of: "】", with: "]").replacing(/\[(\d{1,2}(?::\d{2}){1,2})\s?[-‐‑–—]\s?\d{1,2}(?::\d{2}){1,2}\]/) { "[\($0.1)]" }
    }

    /// Drops time references that point past the end of the meeting, so every link in the notes leads somewhere.
    static func removingUnknownTimes(_ notes: String, lastStart: TimeInterval) -> String {
        var result = notes
        for match in notes.matches(of: /\s?\[(\d{1,2}(?::\d{2}){1,2})\]/).reversed() {
            guard let seconds = seconds(String(match.1)), seconds > lastStart + 30 else { continue }
            result.removeSubrange(match.range)
        }
        return result
    }

    /// "12:34" or "1:02:03" as seconds.
    static func seconds(_ stamp: String) -> TimeInterval? {
        let fields = stamp.split(separator: ":").map { Int($0) }
        guard (2...3).contains(fields.count), !fields.contains(nil) else { return nil }
        return TimeInterval(fields.compactMap { $0 }.reduce(0) { $0 * 60 + $1 })
    }

    // MARK: Questions

    static let answerSystem = """
    You answer questions about one meeting using only the material provided. "Me" is the person asking; "Them" is everyone else.
    - Be direct and brief. Use Markdown when a list or an email draft is asked for.
    - Give the time for each fact you use, copied from the transcript, like [12:34].
    - Copy names, places and numbers exactly as the transcript spells them.
    - If the material does not contain the answer, reply exactly: \(notDiscussed)
    - Never use outside knowledge to fill a gap.
    """

    static let acrossSystem = """
    You answer questions across several of the user's meetings using only the material provided. "Me" is the person asking.
    - Say which meeting each fact comes from, by title and date.
    - Be direct and brief. Use Markdown lists when listing things.
    - If the material does not contain the answer, reply exactly: That doesn't appear in your meetings.
    - Never use outside knowledge to fill a gap.
    """

    /// Words worth searching for: longer than three letters and not filler.
    static func keywords(_ question: String) -> [String] {
        let ignored: Set<String> = ["what", "when", "where", "which", "who", "whom", "that", "this", "these", "those", "with", "from",
                                    "about", "have", "does", "did", "were", "was", "they", "them", "their", "there", "would", "could",
                                    "should", "into", "list", "tell", "give", "make", "write", "meeting", "meetings", "said", "say",
                                    "talk", "talked", "discuss", "discussed", "anything", "everything", "week", "today"]
        return question.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
            .filter { $0.count > 3 && !ignored.contains($0) }
    }

    /// The transcript if it fits; otherwise the notes, the lines matching the question, and the most recent minutes.
    static func material(question: String, meeting: Meeting, segments: [TranscriptSegment], limit: Int) -> String {
        let whole = transcript(segments)
        var text = ""
        let notes = [meeting.notes, meeting.enhanced].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        if !notes[0].isEmpty { text += "<my_notes>\n\(notes[0])\n</my_notes>\n" }
        if whole.count <= limit { return text + "<transcript>\n\(whole)\n</transcript>" }
        if !notes[1].isEmpty { text += "<meeting_notes>\n\(notes[1].prefix(limit / 3))\n</meeting_notes>\n" }
        let words = keywords(question)
        var chosen = Set<Int>()
        var used = 0
        // Lines that mention the question's words, each with the line after it for context.
        for (index, segment) in segments.enumerated() where words.contains(where: { segment.text.lowercased().contains($0) }) {
            for near in [index, index + 1] where near < segments.count && !chosen.contains(near) {
                let size = line(segments[near]).count + 1
                if used + size > limit / 2 { break }
                chosen.insert(near); used += size
            }
        }
        // Then the latest part of the conversation, newest first, until the space is used.
        for index in segments.indices.reversed() where !chosen.contains(index) {
            let size = line(segments[index]).count + 1
            if used + size > limit * 2 / 3 { break }
            chosen.insert(index); used += size
        }
        let excerpt = chosen.sorted().map { line(segments[$0]) }.joined(separator: "\n")
        return text + "<transcript_excerpts>\n\(excerpt)\n</transcript_excerpts>"
    }

    /// Answers from one meeting. `history` is the earlier conversation about it.
    func answer(question: String, meeting: Meeting, segments: [TranscriptSegment], history: [ChatTurn] = []) async throws -> String {
        let material = Self.material(question: question, meeting: meeting, segments: segments, limit: partLimit)
        let recent = history.suffix(4).map { ChatTurn(fromUser: $0.fromUser, text: String($0.text.prefix(600))) }
        let turns = recent + [ChatTurn(fromUser: true, text: "Meeting: \(meeting.title)\n\(material)\n\nQuestion: \(question)")]
        return try await ask(system: Self.answerSystem, turns: turns, maxTokens: 900)
    }

    static func acrossMaterial(meetings: [Meeting], hits: [TranscriptSegment], limit: Int) -> String {
        let names = Dictionary(uniqueKeysWithValues: meetings.map { ($0.id, $0) })
        func label(_ meeting: Meeting) -> String { "\(meeting.title) (\(meeting.started.formatted(date: .abbreviated, time: .omitted)))" }
        var text = ""
        // Newest meetings first: their notes carry the most per character.
        for meeting in meetings.sorted(by: { $0.started > $1.started }) {
            let notes = (meeting.enhanced.isEmpty ? meeting.notes : meeting.enhanced).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !notes.isEmpty else { continue }
            let block = "<meeting title=\"\(label(meeting))\">\n\(notes.prefix(limit / 4))\n</meeting>\n"
            if text.count + block.count > limit * 2 / 3 { break }
            text += block
        }
        var quotes = ""
        for hit in hits {
            guard let meeting = names[hit.meeting] else { continue }
            let quote = "\(label(meeting)) \(line(hit))\n"
            if text.count + quotes.count + quote.count > limit { break }
            quotes += quote
        }
        if !quotes.isEmpty { text += "<transcript_lines>\n\(quotes)</transcript_lines>" }
        return text
    }

    /// Answers across meetings from their notes and the transcript lines that match the question.
    func answerAcross(question: String, meetings: [Meeting], hits: [TranscriptSegment]) async throws -> String {
        let material = Self.acrossMaterial(meetings: meetings, hits: hits, limit: partLimit)
        guard !material.isEmpty else { return "That doesn't appear in your meetings." }
        return try await ask(system: Self.acrossSystem, turns: [ChatTurn(fromUser: true, text: "\(material)\n\nQuestion: \(question)")],
                             maxTokens: 900)
    }

    private func ask(system: String, turns: [ChatTurn], maxTokens: Int) async throws -> String {
        var waits = retryDelays[...]
        while true {
            do { return Self.singleTimes(try await provider.reply(system: system, turns: turns, maxTokens: maxTokens)) }
            catch CloudError.http(429) {
                guard let wait = waits.popFirst() else { throw CloudError.http(429) }
                try await sleep(wait)
            }
        }
    }
}

enum MeetingError: LocalizedError {
    case emptyTranscript, alreadyRecording, systemAudioDenied
    var errorDescription: String? {
        switch self {
        case .emptyTranscript: "There is no transcript yet, so there is nothing to write notes from."
        case .alreadyRecording: "Another meeting is already being recorded. Stop it first."
        case .systemAudioDenied: "Utter can't hear the call. Allow Utter under System Settings → Privacy & Security → Screen & System Audio Recording → System Audio Recording Only."
        }
    }
}
