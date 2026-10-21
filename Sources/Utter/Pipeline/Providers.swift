import Foundation

struct DictationContext: Sendable, Equatable {
    let target: InsertionTarget
    var language: String?
    var prompt: String?
    var dictionary: [String] = []
    var style: AppStyle = .standard
    var category: AppCategory = .general
    /// Text just before the cursor, sent to cleanup only when the user allows it.
    var precedingText: String? = nil
}

/// Providers must cooperate with task cancellation so stage timeouts can finish.
protocol TranscriptionProvider: Sendable {
    func transcribe(audio: RecordedAudio, language: String?, prompt: String?) async throws -> String
}

protocol CleanupProvider: Sendable {
    func clean(raw: String, context: DictationContext) async throws -> String
    /// Shown to the user after each dictation; nil means cleanup is off.
    var serviceName: String? { get }
}
extension CleanupProvider {
    var serviceName: String? { nil }
}

struct PassthroughProvider: CleanupProvider {
    func clean(raw: String, context: DictationContext) async throws -> String { raw }
}

/// Explicit manual-test input; never presented as a transcript of the audio.
struct SampleTextProvider: TranscriptionProvider {
    let text: String
    func transcribe(audio: RecordedAudio, language: String?, prompt: String?) async throws -> String {
        try Task.checkCancellation()
        return text
    }
}

enum PipelineError: LocalizedError {
    case timeout, emptyTranscript, queueFull
    var errorDescription: String? {
        switch self {
        case .timeout: "Text processing timed out. Try again."
        case .emptyTranscript: "No speech was recognized."
        case .queueFull: "The dictation queue is full. Wait for the pending clips to finish."
        }
    }
}

func withStageTimeout<T: Sendable>(
    _ duration: Duration, operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: duration)
            throw PipelineError.timeout
        }
        defer { group.cancelAll() }
        guard let result = try await group.next() else { throw CancellationError() }
        return result
    }
}
