import OSLog

/// Call only for clips captured while the explicit debug setting is enabled.
enum StageTimingLog {
    private static let logger = Logger(subsystem: "org.utter.app", category: "StageTiming")
    static func record(_ stage: String, since start: ContinuousClock.Instant, path: DictationPath) {
        let elapsed = start.duration(to: .now).components
        let milliseconds = Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
        logger.debug("\(path.rawValue, privacy: .public) release_to_\(stage, privacy: .public)_ms=\(milliseconds, privacy: .public)")
    }
}
