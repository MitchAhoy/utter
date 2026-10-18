import SwiftUI

struct TranscriptionSettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var local: LocalModelController
    @ObservedObject var cloud: CloudSettings
    private var busy: Bool { model.isRecording || model.isProcessing || local.state.isPreparing }

    var body: some View {
        Form {
            Section("Dictation") {
                Picker("Mode", selection: $model.mode) {
                    ForEach(DictationMode.allCases) { Text($0.title).tag($0) }
                }
                .disabled(model.isRecording || model.isProcessing)
                Text("On-device dictation turns your speech into text and pastes it at the cursor. Recording only preserves the earlier microphone test flow.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Local speech model") {
                Picker("Model", selection: Binding(get: { local.selectedModel }, set: { local.select($0) })) {
                    ForEach(LocalModel.allCases) { Text($0.title).tag($0) }
                }
                .disabled(busy)
                Text(local.selectedModel.detail).font(.caption).foregroundStyle(.secondary)
                switch local.state {
                case .notInstalled:
                    Label("Model not downloaded", systemImage: "arrow.down.circle")
                    Button("Download & Prepare Model") { local.prepare(download: true) }
                        .disabled(busy)
                case .preparing(let fraction, let message):
                    if let fraction { ProgressView(value: fraction) { Text(message) } }
                    else { ProgressView { Text(message) } }
                    Button("Cancel") { local.cancel() }
                    Text("First-time preparation can take a few minutes. Later launches use the cached model.")
                        .font(.caption).foregroundStyle(.secondary)
                case .ready:
                    Label("Ready · On-device", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                case .failed(let error):
                    Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.orange)
                    Button("Retry Download & Preparation") { local.prepare(download: true) }
                        .disabled(busy)
                }
                Text("Downloads come from Hugging Face and stay in Application Support/Utter/Models. Once prepared, transcription works offline. On-device mode never uploads recordings.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            CloudCredentialsView(cloud: cloud)
        }
        .formStyle(.grouped)
        .onAppear { cloud.refreshKeys() }
    }
}
