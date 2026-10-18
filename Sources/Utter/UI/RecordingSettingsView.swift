import SwiftUI

enum SettingsTab: Hashable { case general, transcription, cleanup, permissions }

struct RecordingSettingsView: View {
    @ObservedObject var model: AppModel
    @State private var tab: SettingsTab
    init(model: AppModel) {
        self.model = model
        _tab = State(initialValue: model.accessibilityGranted && model.microphoneGranted ? .transcription : .permissions)
    }
    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $tab) {
                GeneralSettingsView(model: model, login: model.launchAtLogin)
                    .tabItem { Label("General", systemImage: "gearshape") }.tag(SettingsTab.general)
                TranscriptionSettingsView(model: model, local: model.localModels)
                    .tabItem { Label("Transcription", systemImage: "waveform") }.tag(SettingsTab.transcription)
                Form {
                    Section("Text cleanup") {
                        LabeledContent("Provider", value: "Pass through")
                        Text("Your transcript is inserted as recognized, including punctuation supplied by the speech model.")
                        Text("Claude cleanup remains off while cloud APIs are disconnected. No text is sent to a cloud service.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }.formStyle(.grouped)
                    .tabItem { Label("Cleanup", systemImage: "text.badge.checkmark") }.tag(SettingsTab.cleanup)
                PermissionsSettingsView(model: model)
                    .tabItem { Label("Permissions", systemImage: "lock.shield") }.tag(SettingsTab.permissions)
            }
            Divider()
            Label(model.isRecording ? "Recording…" : model.status,
                  systemImage: model.isRecording ? "mic.fill" : "info.circle")
                .font(.caption).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }
        .frame(width: 620, height: 660)
    }
}
