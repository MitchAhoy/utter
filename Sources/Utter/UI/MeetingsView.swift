import SwiftUI

/// Renders the Markdown the assistant writes: headings, bullets and paragraphs, with times such as
/// [12:34] turned into links that jump to that moment in the transcript.
struct MeetingMarkdown: View {
    let text: String
    var onTime: ((TimeInterval) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(text.split(separator: "\n", omittingEmptySubsequences: true).enumerated()), id: \.offset) { _, raw in
                row(String(raw))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme == "utter-time", let seconds = TimeInterval(url.host ?? "") else { return .systemAction }
            onTime?(seconds)
            return .handled
        })
    }

    @ViewBuilder private func row(_ line: String) -> some View {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let indent = CGFloat(line.prefix { $0 == " " }.count / 2) * 14
        if trimmed.hasPrefix("#") {
            Text(Self.inline(String(trimmed.drop { $0 == "#" || $0 == " " }))).font(.headline).padding(.top, 8)
        } else if let item = Self.bullet(trimmed) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(item.marker).foregroundStyle(.secondary)
                Text(Self.inline(item.text))
            }.padding(.leading, indent)
        } else {
            Text(Self.inline(trimmed))
        }
    }

    static func bullet(_ line: String) -> (marker: String, text: String)? {
        for (prefix, marker) in [("- [ ] ", "☐"), ("- [x] ", "☑"), ("- ", "•"), ("* ", "•")] where line.hasPrefix(prefix) {
            return (marker, String(line.dropFirst(prefix.count)))
        }
        if let match = line.firstMatch(of: /^(\d+)[.)]\s+/) { return ("\(match.1).", String(line[match.range.upperBound...])) }
        return nil
    }

    /// Inline Markdown (bold, italics, code), with each time reference made into a link.
    static func inline(_ line: String) -> AttributedString {
        let linked = line.replacing(/\[(\d{1,2}(?::\d{2}){1,2})\]/) { match in
            MeetingAssistant.seconds(String(match.1)).map { "[\(match.1)](utter-time://\(Int($0)))" } ?? String(match.0)
        }
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: linked, options: options)) ?? AttributedString(line)
    }
}

struct MeetingsView: View {
    @ObservedObject var meetings: MeetingsController
    @ObservedObject var settings: MeetingSettings

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 8) {
                RecordButton(meetings: meetings).padding(.horizontal, 10).padding(.top, 10)
                TextField("Search meetings", text: $meetings.search).textFieldStyle(.roundedBorder).padding(.horizontal, 10)
                List(selection: $meetings.selectedID) {
                    Label("All meetings", systemImage: "bubble.left.and.text.bubble.right").tag(String?.none)
                    Section("Meetings") {
                        ForEach(meetings.meetings) { meeting in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 5) {
                                    if meeting.id == meetings.recordingID {
                                        Image(systemName: "record.circle.fill").foregroundStyle(.red)
                                    }
                                    Text(meeting.title).lineLimit(1)
                                }
                                Text(meeting.started.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            .tag(String?.some(meeting.id))
                            .contextMenu { Button("Delete Meeting", role: .destructive) { meetings.delete(meeting.id) } }
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 320)
        } detail: {
            VStack(spacing: 0) {
                if let meeting = meetings.selected, meetings.selectedID == meeting.id {
                    MeetingDetailView(meetings: meetings, settings: settings, meeting: meeting).id(meeting.id)
                } else {
                    OverallChatView(meetings: meetings, settings: settings)
                }
                if let message = meetings.message {
                    Divider()
                    HStack {
                        Label(message, systemImage: "info.circle").font(.caption).textSelection(.enabled)
                        Spacer()
                        Button("Dismiss") { meetings.dismissMessage() }.buttonStyle(.link).font(.caption)
                    }.padding(10)
                }
            }
        }
        .frame(minWidth: 860, minHeight: 560)
        .onAppear { meetings.reload() }
    }
}

private struct RecordButton: View {
    @ObservedObject var meetings: MeetingsController
    var body: some View {
        if meetings.isRecording {
            Button { meetings.stop() } label: {
                Label("Stop Meeting Notes", systemImage: "stop.circle.fill").frame(maxWidth: .infinity)
            }.controlSize(.large).tint(.red).buttonStyle(.borderedProminent)
        } else {
            Button { meetings.start() } label: {
                Label("Start Meeting Notes", systemImage: "record.circle").frame(maxWidth: .infinity)
            }.controlSize(.large).buttonStyle(.borderedProminent)
        }
    }
}

private enum MeetingPane: String, CaseIterable, Identifiable {
    case notes = "My notes", enhanced = "Enhanced", transcript = "Transcript"
    var id: String { rawValue }
}

private struct MeetingDetailView: View {
    @ObservedObject var meetings: MeetingsController
    @ObservedObject var settings: MeetingSettings
    let meeting: Meeting
    @State private var pane: MeetingPane = .notes
    @State private var jumpTo: TimeInterval?
    @State private var confirmDelete = false

    private var recording: Bool { meetings.recordingID == meeting.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                TextField("Title", text: Binding(get: { meeting.title }, set: { meetings.setTitle($0) }))
                    .textFieldStyle(.plain).font(.title2.bold())
                if recording, let since = meetings.recordingSince {
                    Label { Text(since, style: .timer).monospacedDigit() } icon: {
                        Image(systemName: "waveform").symbolEffect(.variableColor.iterative)
                    }.foregroundStyle(.red)
                    Button("Stop") { meetings.stop() }
                } else if !meetings.isRecording {
                    Button("Resume") { meetings.start(resuming: meeting) }
                        .help("Continue recording; new speech is added to this meeting.")
                }
                Menu {
                    Button("Copy Notes as Markdown") { meetings.copyNotes() }
                    Button("Copy Transcript") { meetings.copyTranscript() }
                    Button("Export Markdown…") { meetings.export() }
                    Divider()
                    Button("Delete Meeting…", role: .destructive) { confirmDelete = true }
                } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).fixedSize()
            }
            HStack {
                Picker("", selection: $pane) { ForEach(MeetingPane.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                Spacer()
                if meetings.pendingChunks > 0 && recording {
                    Text("Transcribing…").font(.caption).foregroundStyle(.secondary)
                }
                Text(meeting.started.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
            }
            Group {
                switch pane {
                case .notes:
                    TextEditor(text: Binding(get: { meeting.notes }, set: { meetings.setNotes($0) }))
                        .font(.body).scrollContentBackground(.hidden)
                        .overlay(alignment: .topLeading) {
                            if meeting.notes.isEmpty {
                                Text("Write as much or as little as you like. When the meeting ends, your notes are expanded from the transcript.")
                                    .foregroundStyle(.tertiary).padding(.leading, 5).allowsHitTesting(false)
                            }
                        }
                case .enhanced: enhanced
                case .transcript:
                    TranscriptView(meetings: meetings, recording: recording, jumpTo: $jumpTo)
                }
            }.frame(maxHeight: .infinity)
            Divider()
            ChatView(messages: meetings.chat, answering: meetings.answering, recipes: settings.recipes.filter { $0.scope == .single },
                     placeholder: "Ask anything about this meeting, or type / for a recipe",
                     onTime: { jumpTo = $0; pane = .transcript },
                     ask: { meetings.ask($0) }, clear: { meetings.clearChat() })
        }
        .padding(16)
        .onChange(of: meetings.enhancingID) { old, new in
            if old == meeting.id && new == nil && !meeting.enhanced.isEmpty { pane = .enhanced }
        }
        .confirmationDialog("Delete this meeting, its transcript and notes?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { meetings.delete(meeting.id) }
        }
    }

    @ViewBuilder private var enhanced: some View {
        if meetings.enhancingID == meeting.id {
            VStack(spacing: 10) { ProgressView(); Text("Writing notes from the transcript…").foregroundStyle(.secondary) }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if meeting.enhanced.isEmpty {
            ContentUnavailableView {
                Label("No enhanced notes yet", systemImage: "sparkles")
            } description: {
                Text(recording ? "They are written when the meeting ends." : "Write them from the transcript and your own notes.")
            } actions: {
                Button("Write Notes Now") { meetings.enhance(meeting.id) }.disabled(meetings.segments.isEmpty)
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Picker("Template", selection: Binding(get: { settings.template(id: meeting.template).id },
                                                          set: { meetings.enhance(meeting.id, template: $0) })) {
                        ForEach(settings.templates) { Text($0.name).tag($0.id) }
                    }.fixedSize().help("Choosing a template rewrites the notes in that layout.")
                    Button { meetings.enhance(meeting.id) } label: { Label("Rewrite", systemImage: "arrow.clockwise") }
                    Spacer()
                }
                ScrollView {
                    MeetingMarkdown(text: meeting.enhanced) { jumpTo = $0; pane = .transcript }.padding(.trailing, 8)
                }
            }
        }
    }
}

private struct TranscriptView: View {
    @ObservedObject var meetings: MeetingsController
    let recording: Bool
    @Binding var jumpTo: TimeInterval?
    @State private var filter = ""
    @State private var highlighted: Int64?

    private var shown: [TranscriptSegment] {
        filter.isEmpty ? meetings.segments : meetings.segments.filter { $0.text.localizedCaseInsensitiveContains(filter) }
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                TextField("Search transcript", text: $filter).textFieldStyle(.roundedBorder)
                Button("Copy All") { meetings.copyTranscript() }.disabled(meetings.segments.isEmpty)
            }
            if meetings.segments.isEmpty {
                ContentUnavailableView(recording ? "Listening…" : "No transcript",
                                       systemImage: "waveform",
                                       description: Text(recording ? "Speech appears here a few seconds after it is said." : ""))
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(shown) { segment in bubble(segment).id(segment.id) }
                        }.padding(.trailing, 8)
                    }
                    .onChange(of: meetings.segments.count) { _, _ in
                        // Follow the conversation while recording, unless the user is searching or reading an earlier moment.
                        if recording, filter.isEmpty, jumpTo == nil, let last = meetings.segments.last {
                            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    }
                    .onAppear { jump(proxy) }
                    .onChange(of: jumpTo) { _, _ in jump(proxy) }
                }
            }
        }
    }

    private func jump(_ proxy: ScrollViewProxy) {
        guard let time = jumpTo else { return }
        filter = ""
        let target = meetings.segments.last { $0.start <= time + 1 } ?? meetings.segments.first
        guard let target else { return }
        highlighted = target.id
        DispatchQueue.main.async {
            withAnimation { proxy.scrollTo(target.id, anchor: .center) }
            jumpTo = nil
        }
    }

    private func bubble(_ segment: TranscriptSegment) -> some View {
        let mine = segment.speaker == .me
        return HStack {
            if mine { Spacer(minLength: 60) }
            VStack(alignment: .leading, spacing: 3) {
                Text("\(segment.speaker.title) · \(MeetingAssistant.stamp(segment.start))").font(.caption2).foregroundStyle(.secondary)
                Text(segment.text).textSelection(.enabled)
            }
            .padding(8)
            .background(mine ? Color.green.opacity(0.18) : Color.secondary.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
            .overlay { if highlighted == segment.id { RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor, lineWidth: 2) } }
            .contextMenu {
                Button("Copy") { meetings.copy(segment.text) }
                Button("Delete", role: .destructive) { meetings.delete(segment: segment) }
            }
            if !mine { Spacer(minLength: 60) }
        }
    }
}

private struct ChatView: View {
    let messages: [ChatMessage]
    let answering: Bool
    let recipes: [MeetingRecipe]
    let placeholder: String
    var tall = false
    var onTime: ((TimeInterval) -> Void)?
    let ask: (String) -> Void
    let clear: () -> Void
    @State private var draft = ""

    private var suggestions: [MeetingRecipe] {
        guard draft.hasPrefix("/") else { return [] }
        let typed = draft.dropFirst().lowercased()
        return recipes.filter { typed.isEmpty || $0.name.lowercased().contains(typed) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !messages.isEmpty || answering {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(messages) { message in
                                if message.fromUser {
                                    Text(message.text).padding(8)
                                        .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
                                        .frame(maxWidth: .infinity, alignment: .trailing)
                                } else {
                                    MeetingMarkdown(text: message.text, onTime: onTime)
                                }
                            }
                            if answering { ProgressView().controlSize(.small) }
                            Color.clear.frame(height: 1).id("end")
                        }.padding(.trailing, 8)
                    }
                    .frame(maxHeight: tall ? .infinity : 210)
                    .onChange(of: messages.count) { _, _ in withAnimation { proxy.scrollTo("end") } }
                    .onChange(of: answering) { _, _ in withAnimation { proxy.scrollTo("end") } }
                    .onAppear { proxy.scrollTo("end") }
                }
            } else if tall { Spacer() }
            if !suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(suggestions) { recipe in
                        Button { draft = ""; ask("/\(recipe.name)") } label: {
                            Label(recipe.name, systemImage: "bolt").frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(.plain).padding(.vertical, 3)
                    }
                }.padding(8).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            }
            HStack {
                TextField(placeholder, text: $draft).textFieldStyle(.roundedBorder).onSubmit(send)
                Menu {
                    ForEach(recipes) { recipe in Button(recipe.name) { ask("/\(recipe.name)") } }
                    if !messages.isEmpty { Divider(); Button("Clear Conversation") { clear() } }
                } label: { Image(systemName: "bolt") }.menuStyle(.borderlessButton).fixedSize().help("Recipes")
                Button("Ask", action: send).disabled(answering || draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !answering else { return }
        draft = ""
        ask(text)
    }
}

private struct OverallChatView: View {
    @ObservedObject var meetings: MeetingsController
    @ObservedObject var settings: MeetingSettings
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("All meetings").font(.title2.bold())
            Text(meetings.meetings.isEmpty
                 ? "Start meeting notes during a call. Utter listens to your microphone and the call audio on this Mac; nothing joins the meeting and no audio is saved."
                 : "Ask across every meeting, for example “What did I promise this week?”")
                .foregroundStyle(.secondary)
            ChatView(messages: meetings.overallChat, answering: meetings.answering,
                     recipes: settings.recipes.filter { $0.scope == .all },
                     placeholder: "Ask anything about your meetings, or type / for a recipe", tall: true,
                     ask: { meetings.ask($0, overall: true) }, clear: { meetings.clearChat(overall: true) })
        }.padding(16)
    }
}

/// Settings for meeting notes: detection, the default template, and the user's own templates and recipes.
struct MeetingSettingsView: View {
    @ObservedObject var settings: MeetingSettings
    let openMeetings: () -> Void
    var body: some View {
        Form {
            Section("Meeting notes") {
                Text("Utter transcribes your microphone and the call audio playing on this Mac. Nothing joins the call and audio is never saved; only text is kept on this Mac. Tell the people you are meeting that you are taking a transcript.")
                    .font(.callout)
                Button("Open Meetings…", action: openMeetings)
                Toggle("Offer to take notes when a call app starts using the microphone", isOn: $settings.detectMeetings)
                Picker("Template for new meetings", selection: $settings.defaultTemplate) {
                    ForEach(settings.templates) { Text($0.name).tag($0.id) }
                }
            }
            Section("Your templates") {
                ForEach($settings.customTemplates) { $template in
                    VStack(alignment: .leading) {
                        HStack {
                            TextField("Name", text: $template.name)
                            Button("Remove", role: .destructive) { settings.customTemplates.removeAll { $0.id == template.id } }
                        }
                        TextEditor(text: $template.instructions).frame(height: 70).font(.callout)
                    }
                }
                Button("Add Template") {
                    settings.customTemplates.append(MeetingTemplate(id: UUID().uuidString, name: "New template",
                        instructions: "Sections: \"Summary\", \"Key points\", \"Action items\". Say what to focus on and how long the notes should be."))
                }
            }
            Section("Your recipes") {
                ForEach($settings.customRecipes) { $recipe in
                    VStack(alignment: .leading) {
                        HStack {
                            TextField("Name", text: $recipe.name)
                            Picker("", selection: $recipe.scope) {
                                Text("One meeting").tag(MeetingRecipe.Scope.single)
                                Text("All meetings").tag(MeetingRecipe.Scope.all)
                            }.labelsHidden().frame(width: 140)
                            Button("Remove", role: .destructive) { settings.customRecipes.removeAll { $0.id == recipe.id } }
                        }
                        TextEditor(text: $recipe.prompt).frame(height: 60).font(.callout)
                    }
                }
                Button("Add Recipe") {
                    settings.customRecipes.append(MeetingRecipe(name: "New recipe", scope: .single,
                                                                prompt: "What should the answer cover, and in what format?"))
                }
            }
        }.formStyle(.grouped)
    }
}
