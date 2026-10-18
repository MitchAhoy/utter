import SwiftUI

struct CloudCredentialsView: View {
    @ObservedObject var cloud: CloudSettings
    var body: some View {
        Section("Cloud access") {
            Toggle("Allow cloud API requests", isOn: $cloud.enabled)
            Text("Off until you enable it. Cloud transcription uploads audio; cleanup and command mode send text to Anthropic. Local mode keeps audio on this Mac.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Transcription provider", selection: $cloud.provider) {
                ForEach(CloudTranscriber.allCases) { Text("\($0.title) · \($0.model)").tag($0) }
            }
        }
        Section("API keys · stored only in Keychain") {
            ForEach(CloudService.allCases) { service in CredentialRow(service: service, cloud: cloud) }
            if let message = cloud.message { Text(message).font(.caption).textSelection(.enabled) }
        }
    }
}
private struct CredentialRow: View {
    let service: CloudService
    @ObservedObject var cloud: CloudSettings
    @State private var value = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(service.title).fontWeight(.medium)
                Spacer()
                Text(cloud.storedKeys.contains(service) ? "Saved in Keychain" : "Not configured")
                    .font(.caption).foregroundStyle(.secondary)
            }
            SecureField("API key", text: $value, prompt: Text("Paste your \(service.title) API key here"))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
                .accessibilityLabel("\(service.title) API key")
            HStack {
                Button("Save") { if cloud.save(value, service: service) { value = "" } }.disabled(value.isEmpty)
                Button("Remove") { cloud.delete(service) }.disabled(!cloud.storedKeys.contains(service))
            }
        }
        .padding(.vertical, 4)
    }
}
struct CleanupSettingsView: View {
    @ObservedObject var cloud: CloudSettings
    var body: some View {
        Form {
            Section("Clean up dictated text") {
                Toggle("Enable Claude cleanup", isOn: $cloud.cleanupEnabled)
                Text("Removes fillers, fixes punctuation, and applies spoken self-corrections. It preserves your wording and never answers questions in your dictation.")
                    .font(.callout).foregroundStyle(.secondary)
                TextField("Model", text: $cloud.cleanupModel)
                HStack {
                    Text("Timeout")
                    Slider(value: $cloud.cleanupTimeout, in: 0.5...5, step: 0.1)
                    Text(String(format: "%.1f s", cloud.cleanupTimeout)).monospacedDigit().frame(width: 50)
                }
                Text("Clips with fewer than four words skip cleanup. On errors or timeout, Utter inserts the original transcript. Verbatim app styles always skip cleanup.")
                    .font(.caption).foregroundStyle(.secondary)
                if !cloud.enabled || !cloud.storedKeys.contains(.anthropic) {
                    Label("Add an Anthropic key and enable cloud access under Transcription to use cleanup.", systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }.formStyle(.grouped)
    }
}
