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
        let cleaner: any CleanupProvider
        let cleanupLimit: Duration
        let transforms: TextTransformOptions
        let selection: Task<String, Error>?
        let editor: (any CommandProvider)?
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
    var onResult: (@MainActor (String, String, DictationContext, DictationPath) -> Void)?
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
                path: DictationPath = .sample, timeout: Duration? = nil, debugTimings: Bool = false,
                cleaner: (any CleanupProvider)? = nil, cleanupLimit: Duration? = nil,
                transforms: TextTransformOptions = TextTransformOptions(),
                selection: Task<String, Error>? = nil, editor: (any CommandProvider)? = nil) -> Bool {
        guard canAcceptClip else { onEvent?(.failed(PipelineError.queueFull.localizedDescription)); return false }
        jobs.append(Job(audio: audio, context: context, transcriber: transcriber,
                        timeout: timeout ?? transcriptionTimeout, path: path, debugTimings: debugTimings, released: .now,
                        cleaner: cleaner ?? cleanup, cleanupLimit: cleanupLimit ?? cleanupTimeout,
                        transforms: transforms, selection: selection, editor: editor))
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
        defer { job.selection?.cancel() }
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
            var resolvedPath = job.path
            if job.path == .auto, let router = job.transcriber as? RoutedTranscriptionProvider {
                resolvedPath = await router.usedLocal ? .local : .cloud
                activePath = resolvedPath
                onEvent?(.processing)
            }
            if job.debugTimings { StageTimingLog.record("transcript", since: released, path: job.path) }
            let cleaned: String
            if let selection = job.selection, let editor = job.editor {
                let selected = try await withTaskCancellationHandler {
                    try await selection.value
                } onCancel: { selection.cancel() }
                cleaned = try await withStageTimeout(.seconds(30)) {
                    try await editor.edit(selection: selected, instruction: transcript, context: job.context)
                }
                guard !cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CloudError.invalidResponse }
            } else {
                var candidate = transcript
                if transcript.split(whereSeparator: \.isWhitespace).count >= 4 {
                    do {
                        candidate = try await withStageTimeout(job.cleanupLimit) {
                            try await job.cleaner.clean(raw: transcript, context: job.context)
                        }
                    } catch {
                        try Task.checkCancellation()
                        candidate = transcript
                    }
                }
                if candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { candidate = transcript }
                cleaned = job.transforms.apply(to: candidate)
            }
            try Task.checkCancellation()
            if job.debugTimings { StageTimingLog.record("cleaned", since: released, path: job.path) }
            onResult?(transcript, cleaned, job.context, resolvedPath)
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
        for job in jobs { job.selection?.cancel() }
        jobs.removeAll()
        worker?.cancel()
    }

    /// Also used by tests to await the complete queue without polling.
    func waitUntilIdle() async {
        while let worker { await worker.value }
    }
}
