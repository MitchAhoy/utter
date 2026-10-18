import Foundation

enum PipelineEvent: Equatable {
    case processing, inserted, failed(String), idle
}

/// Serializes completed clips while the independent recorder accepts the next hold.
@MainActor
final class DictationPipeline {
    private struct Job: Sendable {
        let audio: RecordedAudio
        let context: DictationContext
        let transcriber: any TranscriptionProvider
        let timeout: Duration
        let path: DictationPath
        let debugTimings: Bool
        let released: ContinuousClock.Instant
    }
    private let inserter: any TextInserter
    private let cleanup: any CleanupProvider
    private let transcriptionTimeout: Duration
    private let cleanupTimeout: Duration
    private let maximumPending = 3
    private var jobs: [Job] = []
    private var worker: Task<Void, Never>?
    private var active = false
    private(set) var activePath: DictationPath?
    var onEvent: (@MainActor (PipelineEvent) -> Void)?
    var canAcceptClip: Bool { jobs.count + (active ? 1 : 0) < maximumPending }

    init(inserter: any TextInserter, cleanup: any CleanupProvider = PassthroughProvider(),
         transcriptionTimeout: Duration = .seconds(30), cleanupTimeout: Duration = .milliseconds(1500)) {
        self.inserter = inserter
        self.cleanup = cleanup
        self.transcriptionTimeout = transcriptionTimeout
        self.cleanupTimeout = cleanupTimeout
    }

    @discardableResult
    func submit(audio: RecordedAudio, context: DictationContext, transcriber: any TranscriptionProvider,
                path: DictationPath = .sample, timeout: Duration? = nil, debugTimings: Bool = false) -> Bool {
        guard canAcceptClip else { onEvent?(.failed(PipelineError.queueFull.localizedDescription)); return false }
        jobs.append(Job(audio: audio, context: context, transcriber: transcriber,
                        timeout: timeout ?? transcriptionTimeout, path: path, debugTimings: debugTimings, released: .now))
        startWorkerIfNeeded()
        return true
    }

    private func startWorkerIfNeeded() {
        guard worker == nil, !jobs.isEmpty else { return }
        worker = Task { [weak self] in await self?.drain() }
    }

    private func drain() async {
        while !Task.isCancelled, !jobs.isEmpty {
            let job = jobs.removeFirst()
            active = true
            activePath = job.path
            onEvent?(.processing)
            await process(job)
            active = false
        }
        activePath = nil
        worker = nil
        onEvent?(.idle)
        // A clip may have arrived while cancellation of the old worker completed.
        startWorkerIfNeeded()
    }

    private func process(_ job: Job) async {
        var raw: String?
        let released = job.released
        do {
            let transcript = try await withStageTimeout(job.timeout) {
                try await job.transcriber.transcribe(audio: job.audio, language: job.context.language, prompt: job.context.prompt)
            }
            try Task.checkCancellation()
            guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw PipelineError.emptyTranscript
            }
            raw = transcript
            if job.debugTimings { StageTimingLog.record("transcript", since: released, path: job.path) }
            let cleaned: String
            do {
                let cleaner = cleanup
                let candidate = try await withStageTimeout(cleanupTimeout) {
                    try await cleaner.clean(raw: transcript, context: job.context)
                }
                cleaned = candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? transcript : candidate
            } catch {
                try Task.checkCancellation()
                cleaned = transcript
            }
            try Task.checkCancellation()
            if job.debugTimings { StageTimingLog.record("cleaned", since: released, path: job.path) }
            try await inserter.insert(cleaned, target: job.context.target)
            try Task.checkCancellation()
            if job.debugTimings { StageTimingLog.record("pasted", since: released, path: job.path) }
            onEvent?(.inserted)
        } catch {
            guard !Task.isCancelled else { return }
            var message = error.localizedDescription
            if let raw {
                do {
                    try inserter.copyForRecovery(raw)
                    message += " Text copied to clipboard."
                } catch {
                    message += " Could not copy text to clipboard."
                }
            }
            onEvent?(.failed(message))
        }
    }

    func cancel() {
        jobs.removeAll()
        worker?.cancel()
    }

    /// Also used by tests to await the complete queue without polling.
    func waitUntilIdle() async {
        while let worker { await worker.value }
    }
}
