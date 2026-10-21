import SwiftUI
import UniformTypeIdentifiers
import KeyboardShortcuts

struct DictionarySettingsView: View {
    @ObservedObject var settings: FeatureSettings
    var body: some View {
        Form {
            Section("Personal dictionary") {
                Toggle("Use dictionary terms", isOn: $settings.dictionaryEnabled)
                Text("Add names, products, and specialist terms, one per line. Terms are passed to transcription and cleanup as spelling hints.")
                    .foregroundStyle(.secondary)
                TextEditor(text: $settings.dictionary).font(.body).frame(minHeight: 240)
                Text("\(settings.terms.count) active terms · up to 200 terms")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }
}
struct SnippetSettingsView: View {
    @ObservedObject var settings: FeatureSettings
    var body: some View {
        Form {
            Section("Spoken snippets") {
                Toggle("Expand spoken trigger phrases", isOn: $settings.snippetsEnabled)
                Text("Speak an exact trigger phrase to replace the complete dictation with its expansion. Matching ignores case and final sentence punctuation.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach($settings.snippets) { $snippet in
                Section {
                    TextField("Trigger phrase", text: $snippet.trigger)
                    TextEditor(text: $snippet.expansion).frame(minHeight: 80)
                    Button("Delete Snippet", role: .destructive) { settings.snippets.removeAll { $0.id == snippet.id } }
                }
            }
            Button("Add Snippet", systemImage: "plus") { settings.snippets.append(Snippet(trigger: "", expansion: "")) }
        }.formStyle(.grouped)
    }
}
struct AppStylesSettingsView: View {
    @ObservedObject var settings: FeatureSettings
    var body: some View {
        Form {
            Section("Per-app writing styles") {
                Toggle("Use per-app styles", isOn: $settings.stylesEnabled)
                Text("Styles guide cleanup when it is enabled. Without a style, cleanup picks a tone from the app type (email, chat, code, notes). Verbatim bypasses cleanup. Styles never rewrite on-device transcripts by themselves.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach($settings.styles) { $rule in
                Section {
                    TextField("App bundle identifier", text: $rule.bundleID)
                    Picker("Style", selection: $rule.style) { ForEach(AppStyle.allCases) { Text($0.title).tag($0) } }
                    Button("Delete Style", role: .destructive) { settings.styles.removeAll { $0.id == rule.id } }
                }
            }
            HStack {
                Button("Choose App…") {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [.applicationBundle]
                    panel.directoryURL = URL(fileURLWithPath: "/Applications")
                    panel.allowsMultipleSelection = false
                    if panel.runModal() == .OK, let url = panel.url, let id = Bundle(url: url)?.bundleIdentifier {
                        if !settings.styles.contains(where: { $0.bundleID == id }) {
                            settings.styles.append(AppStyleRule(bundleID: id, style: .standard))
                        }
                    }
                }
                Button("Add by Bundle ID") { settings.styles.append(AppStyleRule(bundleID: "", style: .standard)) }
            }
        }.formStyle(.grouped)
    }
}
struct CommandSettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: FeatureSettings
    @ObservedObject var cloud: CloudSettings
    var body: some View {
        Form {
            Section("Edit selected text by speaking") {
                Toggle("Enable command mode", isOn: $settings.commandEnabled)
                    .onChange(of: settings.commandEnabled) { _, _ in model.refreshCommandShortcut() }
                KeyboardShortcuts.Recorder("Command shortcut", name: .editSelection)
                Text("Select text in another app, hold this shortcut, speak an editing instruction, then release. The edited text replaces the selection.")
                    .foregroundStyle(.secondary)
                Text("Default: Control + Option + Space. Command mode uses your transcription provider and your cleanup service for editing. It does not run shell commands.")
                    .font(.caption).foregroundStyle(.secondary)
                if !cloud.cleanupAvailable {
                    Label("Configure a key for your cleanup service and enable cloud access to use command mode.", systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
        }.formStyle(.grouped)
    }
}
