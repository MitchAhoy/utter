import Foundation

enum CloudTranscriber: String, CaseIterable, Identifiable, Sendable {
    case groq, openAI
    var id: String { rawValue }
    var service: CloudService { self == .groq ? .groq : .openAI }
    var title: String { service.title }
    var model: String { self == .groq ? "whisper-large-v3-turbo" : "gpt-4o-mini-transcribe" }
    var endpoint: URL {
        // Static HTTPS URLs; constructing from components avoids a force unwrap.
        var parts = URLComponents()
        parts.scheme = "https"
        parts.host = self == .groq ? "api.groq.com" : "api.openai.com"
        parts.path = self == .groq ? "/openai/v1/audio/transcriptions" : "/v1/audio/transcriptions"
        return parts.url ?? URL(fileURLWithPath: "/invalid-endpoint")
    }
}

struct CloudTranscriptionProvider: TranscriptionProvider {
    let provider: CloudTranscriber
    let authorize: @Sendable () async throws -> String
    let transport: any CloudTransport
    init(provider: CloudTranscriber, authorize: @escaping @Sendable () async throws -> String,
         transport: any CloudTransport = URLSessionCloudTransport()) {
        self.provider = provider; self.authorize = authorize; self.transport = transport
    }
    func transcribe(audio: RecordedAudio, language: String?, prompt: String?) async throws -> String {
        let key = try await authorize()
        try Task.checkCancellation()
        var body = MultipartAudio()
        body.field("model", provider.model)
        body.field("response_format", "json")
        if let language, !language.isEmpty { body.field("language", language) }
        if let prompt, !prompt.isEmpty { body.field("prompt", String(prompt.prefix(4000))) }
        body.audio(audio.wavData())
        body.finish()
        var request = URLRequest(url: provider.endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(body.boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body.data
        let (data, status) = try await transport.send(request)
        guard (200..<300).contains(status) else { throw CloudError.http(status) }
        struct Response: Decodable { let text: String }
        guard let response = try? JSONDecoder().decode(Response.self, from: data),
              !response.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CloudError.invalidResponse }
        return response.text
    }
}

actor RoutedTranscriptionProvider: TranscriptionProvider {
    private let cloud: (any TranscriptionProvider)?
    private let local: (any TranscriptionProvider)?
    private let allowFallback: Bool
    private(set) var usedLocal = false
    init(cloud: (any TranscriptionProvider)?, local: (any TranscriptionProvider)?, allowFallback: Bool) {
        self.cloud = cloud; self.local = local; self.allowFallback = allowFallback
    }
    func transcribe(audio: RecordedAudio, language: String?, prompt: String?) async throws -> String {
        usedLocal = false
        if let cloud {
            do { return try await cloud.transcribe(audio: audio, language: language, prompt: prompt) }
            catch { try Task.checkCancellation(); if !allowFallback { throw error } }
        }
        guard let local else { throw LocalModelError.notInstalled }
        usedLocal = true
        return try await local.transcribe(audio: audio, language: language, prompt: prompt)
    }
}
