import SwiftUI

struct CloudCredentialsView: View {
    @ObservedObject var cloud: CloudSettings
    var body: some View {
        Section("Cloud access") {
            Toggle("Allow cloud API requests", isOn: $cloud.enabled)
            Text("Off until you enable it. Cloud transcription uploads audio; cleanup and command mode send text to your chosen cleanup service (Groq or Anthropic). Local mode keeps audio on this Mac.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Transcription provider", selection: $cloud.provider) {
                ForEach(CloudTranscriber.allCases) { Text("\($0.title) · \($0.model)").tag($0) }
            }
        }
        Section("API keys · saved only on this Mac") {
            ForEach(CloudService.allCases) { service in CredentialRow(service: service, cloud: cloud) }
            Text("Keys are saved in a private file in Application Support/Utter/Credentials that only your Mac account can read. They are never shown again after saving.")
                .font(.caption).foregroundStyle(.secondary)
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
                Text(cloud.storedKeys.contains(service) ? "Saved" : "Not configured")
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
                Toggle("Enable cleanup", isOn: $cloud.cleanupEnabled)
                Text("Removes fillers and stutters, applies spoken corrections (\u{201C}Tuesday, no, Wednesday\u{201D}), turns \u{201C}new line\u{201D} and enumerated items into formatting, and matches the tone of the app you're typing in. It keeps your wording and never answers questions in your dictation.")
                    .font(.callout).foregroundStyle(.secondary)
                Picker("Service", selection: $cloud.cleanupService) {
                    ForEach(CleanupService.allCases) { Text($0.title).tag($0) }
                }
                switch cloud.cleanupService {
                case .groq: TextField("Groq model", text: $cloud.groqCleanupModel)
                case .anthropic: TextField("Claude model", text: $cloud.cleanupModel)
                }
                HStack {
                    Text("Timeout")
                    Slider(value: $cloud.cleanupTimeout, in: 0.5...5, step: 0.1)
                    Text(String(format: "%.1f s", cloud.cleanupTimeout)).monospacedDigit().frame(width: 50)
                }
                Text("Clips with fewer than four words skip cleanup. On errors, timeouts, or output that looks like an answer instead of a cleanup, Utter inserts the original transcript. Verbatim app styles always skip cleanup.")
                    .font(.caption).foregroundStyle(.secondary)
                if !cloud.cleanupAvailable {
                    Label("Add a \(cloud.cleanupService.credential.title) key and enable cloud access under Transcription to use cleanup.", systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Context") {
                Toggle("Use text before the cursor", isOn: $cloud.cleanupUsesContext)
                Text("Sends up to 300 characters before the cursor with the transcript, so cleanup can continue a sentence with the right capitalization. Password fields are never read. Utter adds a separating space when needed either way.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }
}
