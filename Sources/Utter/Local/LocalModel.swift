import Foundation

enum LocalModel: String, CaseIterable, Codable, Identifiable, Sendable {
    case largeTurbo, small
    var id: String { rawValue }
    var title: String { self == .largeTurbo ? "Large v3 Turbo" : "Small" }
    var detail: String {
        self == .largeTurbo ? "Best accuracy · larger download" : "Faster preparation · smaller download"
    }
    var remoteName: String {
        self == .largeTurbo ? "openai_whisper-large-v3-v20240930_turbo" : "openai_whisper-small"
    }
    var tokenizerRepo: String {
        self == .largeTurbo ? "openai/whisper-large-v3" : "openai/whisper-small"
    }
}

enum DictationMode: String, CaseIterable, Identifiable {
    case local, cloud, auto, recordingOnly
    var id: String { rawValue }
    var title: String {
        switch self {
        case .local: "On-device dictation"
        case .cloud: "Cloud transcription"
        case .auto: "Auto · cloud with local fallback"
        case .recordingOnly: "Recording only"
        }
    }
}

enum DictationPath: String, Sendable {
    case sample, local, cloud, auto, command
    var title: String {
        switch self { case .local: "On-device"; case .sample: "Sample test"; case .cloud: "Cloud"; case .auto: "Auto"; case .command: "Command" }
    }
}

enum LocalModelError: LocalizedError {
    case notInstalled, busy, invalidFiles, noSpeech
    var errorDescription: String? {
        switch self {
        case .notInstalled: "Download and prepare a model in Utter Settings → Transcription first."
        case .busy: "The local model is busy. Wait for preparation or transcription to finish."
        case .invalidFiles: "The local model is incomplete or damaged. Download it again in Transcription settings."
        case .noSpeech: "No speech detected. Try speaking a little louder or check the selected microphone."
        }
    }
}

protocol LocalSpeechEngine: TranscriptionProvider {
    func isInstalled(_ model: LocalModel) async -> Bool
    func prepare(_ model: LocalModel, allowDownload: Bool,
                 progress: @escaping @Sendable (Double?, String) -> Void) async throws
}
