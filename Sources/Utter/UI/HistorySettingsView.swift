import SwiftUI

struct HistorySettingsView: View {
    @ObservedObject var settings: FeatureSettings
    @ObservedObject var history: HistoryController
    @ObservedObject var cloud: CloudSettings
    @State private var selected: HistoryEntry?
    @State private var confirmClear = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Save dictation history on this Mac", isOn: $settings.historyEnabled)
            HStack {
                Picker("Keep for", selection: $settings.retentionDays) {
                    Text("1 day").tag(1); Text("7 days").tag(7); Text("30 days").tag(30); Text("90 days").tag(90)
                }.frame(width: 180)
                Spacer()
                Button("Clear All…", role: .destructive) { confirmClear = true }
            }
            Text("Off by default. Disabling stops new entries; Clear All deletes saved transcripts. Audio is not stored in history.")
                .font(.caption).foregroundStyle(.secondary)
            TextField("Search dictation history", text: $history.search).textFieldStyle(.roundedBorder)
            HSplitView {
                List(history.entries) { entry in
                    Button { selected = entry } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.cleaned).lineLimit(2).foregroundStyle(.primary)
                            Text("\(entry.app) · \(entry.created.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
                    }.buttonStyle(.plain)
                }.frame(minWidth: 190)
                if let selected {
                    VStack(alignment: .leading, spacing: 10) {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Output text").font(.headline)
                                Text(selected.cleaned).textSelection(.enabled)
                                Divider()
                                Text("Raw transcript").font(.headline)
                                Text(selected.raw).foregroundStyle(.secondary).textSelection(.enabled)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                        HStack {
                            Button("Copy Again") { history.copy(selected) }
                            Button("Re-run Cleanup") { history.rerun(selected, cleaner: cloud.cleaner()) }
                                .disabled(history.busy || !cloud.cleanupActive)
                        }
                    }.padding(12).frame(minWidth: 220)
                } else { ContentUnavailableView("Select a dictation", systemImage: "text.alignleft") }
            }
            if let message = history.message { Text(message).font(.caption) }
        }
        .padding(20)
        .onAppear { history.reload() }
        .onChange(of: settings.retentionDays) { _, _ in selected = nil; history.reload() }
        .onChange(of: history.entries) { _, values in
            if let id = selected?.id { selected = values.first { $0.id == id } }
        }
        .confirmationDialog("Delete all saved dictation history?", isPresented: $confirmClear) {
            Button("Delete All", role: .destructive) { selected = nil; history.clear() }
        }
    }
}
