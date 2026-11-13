import AppKit
import Combine

/// Runs meeting notes: recording, the live transcript, enhanced notes, questions, and the saved list.
@MainActor
final class MeetingsController: ObservableObject {
    @Published private(set) var meetings: [Meeting] = []
    @Published var search = "" { didSet { if search != oldValue { reload() } } }
    @Published var selectedID: String? { didSet { if selectedID != oldValue { loadSelection() } } }
    @Published private(set) var selected: Meeting?
    /// Transcript of the selected meeting, in spoken order.
    @Published private(set) var segments: [TranscriptSegment] = []
    @Published private(set) var chat: [ChatMessage] = []
    /// Questions asked across all meetings.
    @Published private(set) var overallChat: [ChatMessage] = []
    @Published private(set) var recordingID: String?
    @Published private(set) var recordingSince: Date?
    @Published private(set) var message: String?
    @Published private(set) var enhancingID: String?
    @Published private(set) var answering = false
    /// Speech captured and still being turned into text.
    @Published private(set) var pendingChunks = 0

    let settings: MeetingSettings
    private let store: MeetingStore
    private let capture: any MeetingCapturing
    /// Built when a recording starts, from the current transcription settings.
    var makeTranscriber: @MainActor () throws -> MeetingTranscriber = { throw CloudError.disabled }
    var makeAssistant: @MainActor () throws -> MeetingAssistant = { throw CloudError.disabled }
    var microphoneUID: @MainActor () -> String = { "" }
    var onRecordingChange: (@MainActor (Bool) -> Void)?
    /// A recording with no speech for this long stops by itself.
    var silenceLimit: TimeInterval = 15 * 60
    var now: @MainActor () -> Date = { Date() }
    /// Shown before the first recording; returns false if the user backs out.
    var confirmConsent: (@MainActor () -> Bool)?

    private var transcriber: MeetingTranscriber?
    /// The transcript of the meeting being recorded, whether or not it is the one on screen.
    private var live: [TranscriptSegment] = []
    private var inFlight: [UUID: Task<Void, Never>] = [:]
    private var summaries: [String: String] = [:]
    private var summarising: Set<String> = []
    private var lastSpeech = Date()
    private var failedChunks = 0
    private var watchdog: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var revision = 0
    /// Meetings removed this session, so speech still being transcribed is not saved against them.
    private var deleted: Set<String> = []

    init(settings: MeetingSettings = MeetingSettings(), store: MeetingStore = MeetingStore(),
         capture: (any MeetingCapturing)? = nil) {
        self.settings = settings
        self.store = store
        self.capture = capture ?? MeetingRecorder()
        self.capture.onChunk = { [weak self] speaker, chunk in self?.received(speaker, chunk) }
    }

    var isRecording: Bool { recordingID != nil }

    // MARK: List

    func reload() {
        revision += 1
        let expected = revision
        let query = search
        Task {
            do {
                let found = try await store.meetings(search: query)
                guard expected == revision else { return }
                meetings = found
                overallChat = try await store.chat(meeting: "")
            } catch { message = error.localizedDescription }
        }
    }

    private func loadSelection() {
        flushEdits()
        guard let id = selectedID else { selected = nil; segments = []; chat = []; return }
        if id == recordingID { segments = live }
        Task {
            do {
                let meeting = try await store.meeting(id: id)
                let lines = try await store.segments(meeting: id)
                let questions = try await store.chat(meeting: id)
                guard selectedID == id else { return }
                selected = meeting
                segments = id == recordingID ? live : lines
                chat = questions
            } catch { message = error.localizedDescription }
        }
    }

    func delete(_ id: String) {
        deleted.insert(id)
        if id == recordingID { stop(enhance: false) }
        Task {
            do {
                try await store.delete(meeting: id)
                if selectedID == id { selectedID = nil }
                reload()
            } catch { message = error.localizedDescription }
        }
    }

    // MARK: Editing

    func setTitle(_ title: String) { edit { $0.title = title } }
    func setNotes(_ notes: String) { edit { $0.notes = notes } }
    func setEnhanced(_ notes: String) { edit { $0.enhanced = notes } }

    private func edit(_ change: (inout Meeting) -> Void) {
        guard var meeting = selected else { return }
        change(&meeting)
        guard meeting != selected else { return }
        selected = meeting
        if let index = meetings.firstIndex(where: { $0.id == meeting.id }) { meetings[index] = meeting }
        saveTask?.cancel()
        saveTask = Task { [store] in
            do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
            try? await store.save(meeting)
        }
    }

    /// Saves typing that is still waiting on the short delay.
    private func flushEdits() {
        guard let saveTask, !saveTask.isCancelled, let meeting = selected else { return }
        saveTask.cancel()
        self.saveTask = nil
        Task { [store] in try? await store.save(meeting) }
    }

    // MARK: Recording

    /// Starts a new meeting, or continues `resuming` so new speech is added to its transcript.
    func start(title: String? = nil, resuming: Meeting? = nil) {
        guard recordingID == nil else { message = MeetingError.alreadyRecording.localizedDescription; return }
        if !settings.consentAcknowledged {
            guard confirmConsent?() ?? true else { return }
            settings.consentAcknowledged = true
        }
        do {
            let transcriber = try makeTranscriber()
            var meeting = resuming ?? Meeting(id: UUID().uuidString, title: title ?? Self.defaultTitle(now()),
                                              started: now(), template: settings.defaultTemplate)
            let offset = resuming.map { ($0.ended ?? now()).timeIntervalSince($0.started) } ?? 0
            meeting.ended = nil
            try capture.start(microphoneUID: microphoneUID(), offset: max(0, offset))
            self.transcriber = transcriber
            live = []
            summaries = [:]; summarising = []; failedChunks = 0
            lastSpeech = now()
            recordingID = meeting.id
            recordingSince = now().addingTimeInterval(-offset)
            message = nil
            let saved = meeting
            Task {
                do {
                    try await store.save(saved)
                    if resuming != nil {
                        // Lines transcribed while the earlier ones were loading are already in `live`.
                        let earlier = try await store.segments(meeting: saved.id)
                        let known = Set(live.map(\.id))
                        live = (earlier.filter { !known.contains($0.id) } + live).sorted { ($0.start, $0.id) < ($1.start, $1.id) }
                        if selectedID == saved.id { segments = live }
                    }
                    reload()
                    selectedID = saved.id
                    selected = saved
                } catch { message = error.localizedDescription }
            }
            onRecordingChange?(true)
            watch()
        } catch { message = error.localizedDescription }
    }

    static func defaultTitle(_ date: Date) -> String { "Meeting · \(date.formatted(date: .abbreviated, time: .shortened))" }

    /// Stops recording, waits for the last speech to be transcribed, then writes enhanced notes.
    func stop(enhance: Bool = true, reason: String? = nil) {
        guard let id = recordingID else { return }
        watchdog?.cancel(); watchdog = nil
        capture.stop()
        recordingID = nil
        recordingSince = nil
        onRecordingChange?(false)
        let ended = now()
        let waiting = Array(inFlight.values)
        if let reason { message = reason }
        Task {
            for task in waiting { await task.value }
            do {
                guard !deleted.contains(id), var meeting = try await store.meeting(id: id) else { return }
                if selected?.id == id, let shown = selected { meeting = shown }
                meeting.ended = ended
                try await store.save(meeting)
                if selectedID == id { selected = meeting }
                reload()
                if enhance, try await !store.segments(meeting: id).isEmpty { self.enhance(id) }
            } catch { message = error.localizedDescription }
        }
    }

    /// Dictation uses the same microphone; its words should not appear as "Me" in the meeting.
    func setDictating(_ dictating: Bool) { capture.microphonePaused = dictating }

    private func watch() {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(20)) } catch { return }
                self?.checkRecording()
            }
        }
    }

    /// Stops after a long silence, and says so when the Mac's audio has never been heard.
    func checkRecording() {
        guard let since = recordingSince, recordingID != nil else { return }
        if now().timeIntervalSince(lastSpeech) >= silenceLimit {
            stop(reason: "Stopped the meeting after \(Int(silenceLimit / 60)) minutes of silence.")
        } else if !capture.heardSystemAudio, now().timeIntervalSince(since) >= 45, message == nil {
            message = MeetingError.systemAudioDenied.localizedDescription
        }
    }

    private func received(_ speaker: Speaker, _ chunk: SpeechChunk) {
        guard let id = recordingID, let transcriber else { return }
        lastSpeech = now()
        pendingChunks += 1
        let key = UUID()
        inFlight[key] = Task {
            defer { pendingChunks -= 1; inFlight[key] = nil }
            do {
                guard let text = try await transcriber.text(for: chunk) else { return }
                await add(TranscriptSegment(meeting: id, speaker: speaker, start: chunk.start, text: text))
            } catch is CancellationError {
            } catch {
                failedChunks += 1
                message = "Some speech could not be transcribed (\(failedChunks) so far): \(error.localizedDescription)"
            }
        }
    }

    private func add(_ segment: TranscriptSegment) async {
        guard !deleted.contains(segment.meeting) else { return }
        let near = { (other: TranscriptSegment) in abs(other.start - segment.start) < 20 }
        do {
            if segment.speaker == .me {
                // On loudspeakers the microphone hears the call too; keep it only once, as "Them".
                if MeetingTranscriber.isEcho(segment.text, of: live.filter { $0.speaker == .them && near($0) }.map(\.text)) { return }
            } else {
                let played = live.filter { $0.speaker == .them && near($0) }.map(\.text) + [segment.text]
                for echo in live where echo.speaker == .me && near(echo) && MeetingTranscriber.isEcho(echo.text, of: played) {
                    try await store.delete(segment: echo.id)
                    live.removeAll { $0.id == echo.id }
                }
            }
            let saved = try await store.add(segment)
            let index = live.firstIndex { $0.start > saved.start } ?? live.count
            live.insert(saved, at: index)
            if selectedID == segment.meeting { segments = live }
            summariseFinishedParts()
        } catch { message = error.localizedDescription }
    }

    /// Condenses each full part of a long transcript while the meeting is still running.
    private func summariseFinishedParts() {
        guard let assistant = try? makeAssistant() else { return }
        for part in MeetingAssistant.parts(live, limit: assistant.partLimit).dropLast()
        where summaries[part] == nil && !summarising.contains(part) {
            summarising.insert(part)
            Task {
                if let summary = try? await assistant.summary(ofPart: part) { summaries[part] = summary }
                summarising.remove(part)
            }
        }
    }

    func delete(segment: TranscriptSegment) {
        Task {
            do {
                try await store.delete(segment: segment.id)
                live.removeAll { $0.id == segment.id }
                segments.removeAll { $0.id == segment.id }
            } catch { message = error.localizedDescription }
        }
    }

    // MARK: Enhanced notes

    /// Writes (or rewrites) the enhanced notes, optionally switching to another template first.
    func enhance(_ id: String, template: String? = nil) {
        guard enhancingID == nil else { return }
        enhancingID = id
        Task {
            defer { enhancingID = nil }
            do {
                let assistant = try makeAssistant()
                guard var meeting = try await store.meeting(id: id) else { return }
                if selected?.id == id, let shown = selected { meeting = shown }
                if let template { meeting.template = template }
                let lines = try await store.segments(meeting: id)
                let notes = try await assistant.notes(meeting: meeting, segments: lines,
                                                      template: settings.template(id: meeting.template), summaries: summaries)
                // Typing may have continued while the notes were being written.
                if selected?.id == id, let shown = selected { meeting.notes = shown.notes; meeting.title = shown.title }
                meeting.enhanced = notes
                try await store.save(meeting)
                if selectedID == id { selected = meeting }
                reload()
                message = nil
            } catch { message = "Enhanced notes could not be written: \(error.localizedDescription) Your own notes and the transcript are unchanged." }
        }
    }

    // MARK: Questions

    /// Asks about the selected meeting, or about every meeting when `overall` is true. "/name" runs a recipe.
    func ask(_ input: String, overall: Bool = false) {
        let typed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty, !answering else { return }
        let recipe = MeetingRecipe.match(typed, in: settings.recipes, scope: overall ? .all : .single)
        let question = recipe?.prompt ?? typed
        let shown = recipe.map { "/\($0.name)" } ?? typed
        let meeting = overall ? nil : selected
        guard overall || meeting != nil else { return }
        let scope = meeting?.id ?? ""
        answering = true
        Task {
            defer { answering = false }
            await record(ChatMessage(meeting: scope, fromUser: true, text: shown))
            do {
                let assistant = try makeAssistant()
                let reply: String
                if let meeting {
                    let lines = try await store.segments(meeting: meeting.id)
                    let history = chat.dropLast().map { ChatTurn(fromUser: $0.fromUser, text: $0.text) }
                    reply = try await assistant.answer(question: question, meeting: selected ?? meeting, segments: lines, history: Array(history))
                } else {
                    let all = try await store.meetings()
                    let hits = try await store.matchingSegments(words: MeetingAssistant.keywords(question))
                    reply = try await assistant.answerAcross(question: question, meetings: all, hits: hits)
                }
                await record(ChatMessage(meeting: scope, fromUser: false, text: reply))
            } catch {
                await record(ChatMessage(meeting: scope, fromUser: false, text: "Couldn't answer: \(error.localizedDescription)"))
            }
        }
    }

    private func record(_ entry: ChatMessage) async {
        do {
            try await store.add(entry)
            let all = try await store.chat(meeting: entry.meeting)
            if entry.meeting.isEmpty { overallChat = all } else if selectedID == entry.meeting { chat = all }
        } catch { message = error.localizedDescription }
    }

    func clearChat(overall: Bool = false) {
        let scope = overall ? "" : (selectedID ?? "")
        guard overall || !scope.isEmpty else { return }
        Task {
            try? await store.clearChat(meeting: scope)
            if overall { overallChat = [] } else { chat = [] }
        }
    }

    // MARK: Copy and export

    static func markdown(meeting: Meeting, segments: [TranscriptSegment], transcript: Bool) -> String {
        var text = "# \(meeting.title)\n\n\(meeting.started.formatted(date: .long, time: .shortened))\n"
        let enhanced = meeting.enhanced.trimmingCharacters(in: .whitespacesAndNewlines)
        let own = meeting.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !enhanced.isEmpty { text += "\n\(enhanced)\n" }
        if !own.isEmpty { text += "\n## My notes\n\n\(own)\n" }
        if transcript && !segments.isEmpty { text += "\n## Transcript\n\n\(MeetingAssistant.transcript(segments))\n" }
        return text
    }

    func copyNotes() {
        guard let meeting = selected else { return }
        copy(Self.markdown(meeting: meeting, segments: [], transcript: false), "Notes copied.")
    }
    func copyTranscript() { copy(MeetingAssistant.transcript(segments), "Transcript copied.") }
    func copy(_ text: String, _ confirmation: String = "Copied.") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        message = confirmation
    }

    func export() {
        guard let meeting = selected else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = meeting.title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: ".") + ".md"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Self.markdown(meeting: meeting, segments: segments, transcript: true).write(to: url, atomically: true, encoding: .utf8)
            message = "Exported to \(url.lastPathComponent)."
        } catch { message = error.localizedDescription }
    }

    func dismissMessage() { message = nil }
}
