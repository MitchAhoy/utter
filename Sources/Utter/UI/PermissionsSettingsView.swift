import SwiftUI

struct PermissionsSettingsView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        Form {
            Section("Set up Utter") {
                Text("Allow Microphone access and enable Utter in Accessibility. Then focus a text field and hold your shortcut to dictate.")
                Text("After an ad-hoc rebuild, macOS may require removing and re-adding this app in Accessibility.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Reveal This Utter App") { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) }
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
                Button("Retry Shortcut Monitor") { model.retryHotkeyMonitor() }
                if model.accessibilityGranted && !model.shortcutReady {
                    Text("If the monitor still cannot start, remove and re-add Utter in Accessibility, then relaunch.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}
