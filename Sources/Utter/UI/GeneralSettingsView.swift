import SwiftUI
import KeyboardShortcuts

struct GeneralSettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var login: LaunchAtLoginController
    var body: some View {
        Form {
            Section("Push to talk") {
                Picker("Hold to record", selection: $model.hotkey) {
                    ForEach(HotkeyChoice.allCases) { choice in
                        Text(choice.title).tag(choice)
                    }
                }
                if model.hotkey == .custom {
                    KeyboardShortcuts.Recorder("Shortcut", name: .pushToTalk)
                    Text("Choose a key with modifiers, then hold the combination while speaking.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if model.hotkey == .fn {
                    Text("Set System Settings → Keyboard → “Press 🌐 key to” to “Do Nothing” to avoid the emoji picker or macOS dictation.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Play start and stop sounds", isOn: $model.sounds)
                Text("Taps shorter than 250 ms are ignored. Recordings stop after 5 minutes.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Input") {
                Picker("Microphone", selection: $model.microphoneUID) {
                    Text("System default").tag("")
                    ForEach(model.microphones) { device in Text(device.name).tag(device.id) }
                    if !model.microphoneUID.isEmpty && !model.microphones.contains(where: { $0.id == model.microphoneUID }) {
                        Text("Selected microphone unavailable").tag(model.microphoneUID)
                    }
                }
                .disabled(model.isRecording)
                Button("Refresh Microphones") { model.refreshMicrophones() }
                Picker("Language", selection: $model.language) {
                    ForEach(DictationLanguage.choices) { Text($0.name).tag($0.id) }
                }
                .disabled(model.isRecording)
            }
            Section("Startup") {
                Toggle("Launch at login", isOn: Binding(get: { login.enabled }, set: { login.setEnabled($0) }))
                if login.requiresApproval {
                    Button("Approve in Login Items…") { login.openSettings() }
                }
                if let error = login.errorMessage { Text(error).font(.caption).foregroundStyle(.orange) }
            }
            Section("Debug recording") {
                Toggle("Save the last recording as a WAV file", isOn: $model.debugRecording)
                Text("Off by default. When enabled, each clip replaces ~/Library/Application Support/Utter/debug/last-recording.wav. Turning this off stops saving; it does not delete an existing file.")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                if let url = model.lastRecordingURL {
                    Button("Reveal Last Recording") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
            }
            Section("Test text insertion") {
                TextField("Sample text", text: $model.sampleText, axis: .vertical)
                    .lineLimit(2...4)
                    .disabled(model.pasteTestArmed || model.isRecording)
                Button(model.pasteTestActionTitle) {
                    model.togglePasteTest()
                }
                .disabled(!model.pasteTestArmed && (model.isRecording || model.isProcessing))
                if let blocker = model.pasteTestBlocker {
                    Label(blocker, systemImage: "exclamationmark.circle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(model.pasteTestArmed
                     ? "Armed. Focus a text field in another app, then hold and release your shortcut. This inserts the sample above once."
                     : "Test pasting without an API. The next recording inserts this sample text instead of transcribing speech. Short taps leave the test armed.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
