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
        let cursor: Task<CursorContext, Never>?
        let shareCursorText: Bool
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
    /// What cleanup did for the clip that was just inserted, e.g. "Cleaned by Groq · 0.3s".
    private(set) var lastCleanupNote: String?
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
                selection: Task<String, Error>? = nil, editor: (any CommandProvider)? = nil,
                cursor: Task<CursorContext, Never>? = nil, shareCursorText: Bool = false) -> Bool {
        guard canAcceptClip else { onEvent?(.failed(PipelineError.queueFull.localizedDescription)); return false }
        jobs.append(Job(audio: audio, context: context, transcriber: transcriber,
                        timeout: timeout ?? transcriptionTimeout, path: path, debugTimings: debugTimings, released: .now,
                        cleaner: cleaner ?? cleanup, cleanupLimit: cleanupLimit ?? cleanupTimeout,
                        transforms: transforms, selection: selection, editor: editor,
                        cursor: cursor, shareCursorText: shareCursorText))
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
        lastCleanupNote = nil
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
            // The cursor read started at key-down, so it is normally finished by now.
            var context = job.context
            var preceding: String?
            if let cursor = job.cursor {
                let found = try? await withStageTimeout(.milliseconds(250)) { await cursor.value }
                preceding = found?.precedingText
                if context.category == .general, let found {
                    context.category = AppCategory.from(bundleID: context.target.bundleID, windowTitle: found.windowTitle)
                }
                if job.shareCursorText { context.precedingText = preceding.map { String($0.suffix(300)) } }
            }
            let cleanupContext = context
            let cleaned: String
            let inserted: String
            if let selection = job.selection, let editor = job.editor {
                let selected = try await withTaskCancellationHandler {
                    try await selection.value
                } onCancel: { selection.cancel() }
                cleaned = try await withStageTimeout(.seconds(30)) {
                    try await editor.edit(selection: selected, instruction: transcript, context: cleanupContext)
                }
                guard !cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CloudError.invalidResponse }
                inserted = cleaned
            } else {
                let spoken = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                var candidate = spoken
                var note: String?
                if !(job.cleaner is PassthroughProvider) {
                    let name = job.cleaner.serviceName ?? "Cleanup"
                    if spoken.split(whereSeparator: \.isWhitespace).count < 4 {
                        note = "Cleanup skipped · under 4 words"
                    } else if cleanupContext.style == .verbatim {
                        note = "Cleanup skipped · verbatim style"
                    } else {
                        let started = ContinuousClock.now
                        do {
                            candidate = try await withStageTimeout(job.cleanupLimit) {
                                try await job.cleaner.clean(raw: spoken, context: cleanupContext)
                            }
                            let seconds = String(format: "%.1fs", Self.seconds(started.duration(to: .now)))
                            note = candidate == spoken ? "\(name) made no changes · \(seconds)" : "Cleaned by \(name) · \(seconds)"
                        } catch {
                            try Task.checkCancellation()
                            candidate = spoken
                            switch error {
                            case PipelineError.timeout: note = "\(name) timed out · raw text"
                            case CloudError.http(429): note = "\(name) rate limit reached · raw text"
                            case CloudError.http(let code): note = "\(name) error \(code) · raw text"
                            case CloudError.missingKey: note = "No \(name) key · raw text"
                            default: note = "\(name) failed · raw text"
                            }
                        }
                        // Fall back to the transcript if the model answered or added content instead of cleaning.
                        if candidate != spoken && (candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || !CleanupPrompt.isPlausible(candidate, raw: spoken)) {
                            candidate = spoken
                            note = "\(name) output rejected · raw text"
                        }
                    }
                }
                lastCleanupNote = note
                if let note { StageTimingLog.cleanup(note) }
                cleaned = job.transforms.apply(to: candidate)
                inserted = InsertionSpacing.adjust(cleaned, after: preceding)
            }
            try Task.checkCancellation()
            if job.debugTimings { StageTimingLog.record("cleaned", since: released, path: job.path) }
            onResult?(transcript, cleaned, job.context, resolvedPath)
            try await inserter.insert(inserted, target: job.context.target)
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

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
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
