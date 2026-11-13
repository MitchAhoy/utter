import Foundation

/// Turns chunks of meeting audio into text, riding out rate limits and filtering what Whisper invents.
struct MeetingTranscriber: Sendable {
    let primary: any TranscriptionProvider
    /// Used when the primary keeps failing, typically the on-device model.
    var fallback: (any TranscriptionProvider)?
    var language: String?
    var prompt: String?
    /// Waits tried, in order, when the service is over its per-minute allowance.
    var retryDelays: [Duration] = [.seconds(5), .seconds(15), .seconds(30)]
    var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }

    /// The words in the chunk, or nil when there were none worth keeping.
    func text(for chunk: SpeechChunk) async throws -> String? {
        let raw = try await recognise(chunk.audio)
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return Self.isInvented(text, duration: chunk.audio.duration) ? nil : text
    }

    private func recognise(_ audio: RecordedAudio) async throws -> String {
        var waits = retryDelays[...]
        while true {
            do {
                return try await primary.transcribe(audio: audio, language: language, prompt: prompt)
            } catch PipelineError.emptyTranscript, CloudError.invalidResponse {
                return ""
            } catch CloudError.http(429) {
                // With an on-device model ready there is no reason to wait for the allowance.
                if let fallback { return try await fallback.transcribe(audio: audio, language: language, prompt: prompt) }
                guard let wait = waits.popFirst() else { throw CloudError.http(429) }
                try await sleep(wait)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                guard let fallback else { throw error }
                return try await fallback.transcribe(audio: audio, language: language, prompt: prompt)
            }
        }
    }

    /// Whisper fills near-silence with stock phrases from its training videos.
    static func isInvented(_ text: String, duration: TimeInterval) -> Bool {
        let plain = text.lowercased().filter { $0.isLetter || $0.isNumber || $0 == " " }.trimmingCharacters(in: .whitespaces)
        if plain.isEmpty { return true }
        let never = ["thanks for watching", "thank you for watching", "subtitles by", "amaraorg", "please subscribe",
                     "like and subscribe", "transcribed by", "see you in the next video"]
        if never.contains(where: plain.contains) { return true }
        // Real, but so often invented on a short noise that a brief chunk of only this is dropped.
        let doubtful: Set<String> = ["thank you", "thanks", "you", "bye", "bye bye", "okay", "ok", "so", "yeah", "hmm", "mm", "uh", "oh"]
        return duration < 1.5 && doubtful.contains(plain)
    }

    /// True when `text` from the microphone is the loudspeaker being picked up again:
    /// most of its words also appear in what the Mac was playing at that moment.
    static func isEcho(_ text: String, of played: [String]) -> Bool {
        func words(_ value: String) -> [String] {
            value.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        }
        let spoken = words(text)
        guard spoken.count >= 4 else { return false }
        var available: [String: Int] = [:]
        for word in played.flatMap(words) { available[word, default: 0] += 1 }
        var shared = 0
        for word in spoken where (available[word] ?? 0) > 0 {
            available[word, default: 0] -= 1
            shared += 1
        }
        return Double(shared) / Double(spoken.count) >= 0.7
    }
}
