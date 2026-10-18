import Foundation
@main
struct CleanupCheck {
    static func main() async throws {
        guard let key = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !key.isEmpty else {
            print("SKIP: ANTHROPIC_API_KEY is not set; no live API calls made.")
            return
        }
        let model = ProcessInfo.processInfo.environment["ANTHROPIC_MODEL"] ?? "claude-haiku-5-5"
        let provider = ClaudeCleanupProvider(model: model, timeout: 15, authorize: { key })
        let context = DictationContext(target: .init(processID: 0, appName: "Cleanup validation", bundleID: "org.utter.validation"))
        var failures = 0
        for (index, fixture) in CleanupCases.all.enumerated() {
            let result = try await provider.clean(raw: fixture.raw, context: context)
            if result != fixture.expected { failures += 1; print("FAIL: cleanup fixture \(index + 1)") }
        }
        print("Live cleanup: \(CleanupCases.all.count - failures)/\(CleanupCases.all.count) exact matches.")
        if failures > 0 { throw RecordingError.message("Live cleanup output did not match the expected corpus. Review before release.") }
    }
}
