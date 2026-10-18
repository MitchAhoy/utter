import SwiftUI
import KeyboardShortcuts

struct RecordingSettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            if !model.accessibilityGranted || !model.microphoneGranted {
                Section("Set up Utter") {
                    Text("Allow Microphone access and enable Utter in Accessibility using the buttons below. Then focus a text field and hold your shortcut to record.")
                    Text("Audio stays on this Mac. Transcription is not connected yet.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
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
            Section("Test text insertion") {
                TextField("Sample text", text: $model.sampleText, axis: .vertical)
                    .lineLimit(2...4)
                    .disabled(model.pasteTestArmed || model.isRecording)
                Button(model.pasteTestArmed ? "Cancel Paste Test" : "Arm Paste Test") {
                    model.togglePasteTest()
                }
                .disabled(model.isRecording || !model.accessibilityGranted || model.isProcessing)
                Text(model.pasteTestArmed
                     ? "Armed. Focus a text field in another app, then hold and release your shortcut. This inserts the sample above once."
                     : "Test pasting without an API. The next recording inserts this sample text instead of transcribing speech. Short taps leave the test armed.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Permissions") {
                LabeledContent("Accessibility", value: model.accessibilityGranted ? "Allowed" : "Required")
                Button("Open Accessibility Settings…") { model.openAccessibility() }
                LabeledContent("Microphone", value: model.microphoneGranted ? "Allowed" : "Required")
                HStack {
                    Button("Allow Microphone") { Task { await model.requestMicrophone() } }
                        .disabled(model.microphoneGranted)
                    Button("Open Microphone Settings…") { model.openMicrophone() }
                }
                Button("Retry Shortcut Monitor") { model.refreshPermissions() }
                if model.accessibilityGranted && !model.shortcutReady {
                    Text("If the monitor still cannot start, remove and re-add Utter in Accessibility, then relaunch.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Debug recording") {
                Toggle("Save the last recording as a WAV file", isOn: $model.debugRecording)
                Text("Off by default. When enabled, each clip replaces ~/Library/Application Support/Utter/debug/last-recording.wav. Turning this off stops saving; it does not delete an existing file.")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                if let url = model.lastRecordingURL {
                    Button("Reveal Last Recording") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
            }
            Section {
                Label(model.isRecording ? "Recording…" : model.status,
                      systemImage: model.isRecording ? "mic.fill" : "info.circle")
                    .font(.callout).textSelection(.enabled)
                Text("Recording + paste test · No transcription or API calls")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 660)
    }
}
