import OSLog

/// Timing and cleanup outcomes only; never transcript text or keys.
enum StageTimingLog {
    private static let logger = Logger(subsystem: "org.utter.app", category: "StageTiming")
    /// Call only for clips captured while the explicit debug setting is enabled.
    static func record(_ stage: String, since start: ContinuousClock.Instant, path: DictationPath) {
        let elapsed = start.duration(to: .now).components
        let milliseconds = Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
        logger.notice("\(path.rawValue, privacy: .public) release_to_\(stage, privacy: .public)_ms=\(milliseconds, privacy: .public)")
    }
    /// Service, result and duration, e.g. "Cleaned by Groq · 0.3s".
    static func cleanup(_ note: String) {
        logger.notice("cleanup: \(note, privacy: .public)")
    }
}
