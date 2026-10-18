import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, transcription, cleanup, dictionary, snippets, styles, commands, history, permissions, about
    var id: String { rawValue }
    var title: String { self == .styles ? "App Styles" : rawValue.capitalized }
    var icon: String {
        switch self {
        case .general: "gearshape"; case .transcription: "waveform"; case .cleanup: "text.badge.checkmark"
        case .dictionary: "character.book.closed"; case .snippets: "text.insert"; case .styles: "textformat"
        case .commands: "command"; case .history: "clock"; case .permissions: "lock.shield"; case .about: "info.circle"
        }
    }
}
struct RecordingSettingsView: View {
    @ObservedObject var model: AppModel
    @State private var tab: SettingsTab?
    init(model: AppModel, initialTab: SettingsTab? = nil) {
        self.model = model
        _tab = State(initialValue: initialTab ?? (model.accessibilityGranted && model.microphoneGranted ? .transcription : .permissions))
    }
    var body: some View {
        VStack(spacing: 0) {
            NavigationSplitView {
                List(SettingsTab.allCases, selection: $tab) { item in
                    Label(item.title, systemImage: item.icon).tag(item)
                }
                .navigationSplitViewColumnWidth(165)
            } detail: {
                VStack(alignment: .leading, spacing: 0) {
                    Text((tab ?? .general).title).font(.title2.bold()).padding(.horizontal, 24).padding(.top, 20)
                    switch tab ?? .general {
                    case .general: GeneralSettingsView(model: model, login: model.launchAtLogin)
                    case .transcription: TranscriptionSettingsView(model: model, local: model.localModels, cloud: model.cloud)
                    case .cleanup: CleanupSettingsView(cloud: model.cloud)
                    case .dictionary: DictionarySettingsView(settings: model.features)
                    case .snippets: SnippetSettingsView(settings: model.features)
                    case .styles: AppStylesSettingsView(settings: model.features)
                    case .commands: CommandSettingsView(model: model, settings: model.features, cloud: model.cloud)
                    case .history: HistorySettingsView(settings: model.features, history: model.history, cloud: model.cloud)
                    case .permissions: PermissionsSettingsView(model: model)
                    case .about: AboutSettingsView(model: model, updates: model.updates)
                    }
                }
            }
            Divider()
            Label(model.isRecording ? "Recording…" : model.status, systemImage: model.isRecording ? "mic.fill" : "info.circle")
                .font(.caption).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(12)
        }.frame(width: 840, height: 690)
    }
}
struct AboutSettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var updates: UpdateController
    var body: some View {
        Form {
            Section("Utter") {
                Text("Speak naturally. Keep your flow.").font(.headline)
                Text("Open-source push-to-talk dictation for macOS. MIT licensed.")
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development")
                Button("Check for Updates…") { updates.check() }.disabled(!updates.canCheck)
                if !updates.configured { Text("Update hosting and signing keys are configured when preparing a public release.").font(.caption).foregroundStyle(.secondary) }
                else { Toggle("Check for updates automatically", isOn: Binding(get: { updates.automaticallyChecks }, set: { updates.automaticallyChecks = $0 })) }
            }
            Section("Privacy") {
                Text("No telemetry or analytics. On-device mode keeps speech on this Mac. Cloud access, history, and debug audio are controlled separately in Settings.")
            }
            Section("Current readiness") {
                LabeledContent("Shortcut", value: model.hotkey.title)
                LabeledContent("Monitor", value: model.shortcutReady ? "Listening" : "Not ready")
                LabeledContent("Accessibility", value: model.accessibilityGranted ? "Allowed" : "Required")
                LabeledContent("Microphone", value: model.microphoneGranted ? "Allowed" : "Required")
                Button("Restart Shortcut Monitor") { model.retryHotkeyMonitor() }
                Button("Reveal This App") { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) }
            }
        }.formStyle(.grouped)
    }
}
