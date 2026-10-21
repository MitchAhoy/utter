import Foundation
@main
struct CleanupCheck {
    static func main() async throws {
        setvbuf(stdout, nil, _IOLBF, 0)
        let env = ProcessInfo.processInfo.environment
        let provider: any CleanupProvider
        let label: String
        if let key = env["GROQ_API_KEY"], !key.isEmpty {
            let model = env["GROQ_MODEL"] ?? GroqCleanupProvider.defaultModel
            let effort = env["GROQ_REASONING"]
            provider = GroqCleanupProvider(model: model, timeout: 15, reasoningEffort: effort, authorize: { key })
            label = "Groq \(model) reasoning=\(effort ?? GroqCleanupProvider.fastestReasoning(for: model) ?? "default")"
        } else if let key = env["ANTHROPIC_API_KEY"], !key.isEmpty {
            let model = env["ANTHROPIC_MODEL"] ?? "claude-haiku-5-5"
            provider = ClaudeCleanupProvider(model: model, timeout: 15, authorize: { key }); label = "Claude \(model)"
        } else {
            print("SKIP: set GROQ_API_KEY or ANTHROPIC_API_KEY; no live API calls made.")
            return
        }
        let context = DictationContext(target: .init(processID: 0, appName: "Cleanup validation", bundleID: "org.utter.validation"))
        var failures = 0
        var timings: [Double] = []
        for (index, fixture) in CleanupCases.all.enumerated() {
            // Free API tiers allow about 30 requests a minute; pace and retry instead of failing.
            if let pause = env["CHECK_PAUSE_MS"].flatMap(Int.init), pause > 0 { try await Task.sleep(for: .milliseconds(pause)) }
            var result = ""
            var elapsed = Duration.zero
            var attempt = 0
            while true {
                let start = ContinuousClock.now
                do {
                    result = try await provider.clean(raw: fixture.raw, context: context)
                    elapsed = start.duration(to: .now)
                    break
                } catch CloudError.http(429) where attempt < 5 {
                    attempt += 1
                    try await Task.sleep(for: .seconds(5 * attempt))
                } catch {
                    result = "ERROR: \(error)"
                    break
                }
            }
            if CleanupPrompt.shouldClean(fixture.raw, context: context) {
                timings.append(Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15)
            }
            if result != fixture.expected {
                failures += 1
                print("DIFF \(index + 1): expected \(fixture.expected.debugDescription) got \(result.debugDescription)")
            }
        }
        if env["CHECK_LONG"] == "1" {
            // Realistic 20 to 40 second dictations; prints output for review, timing only.
            let samples = [
                "um so hey sam I wanted to follow up on the uh the campaign numbers from last week so basically the cost per lead came in at around forty two dollars which is like way better than the sixty we had in september and I think we should um push more budget into the lookalike audiences no actually the retargeting audiences because that's where most of the conversions came from anyway let me know what you think thanks",
                "okay so things I need to do today first call the accountant about the BAS second finish the landing page copy for the new client and third um book flights to melbourne for the conference which is on the twelfth no the fourteenth of november",
                "can you refactor the fetchUserByID function in utils dot ts so that it uh caches the result for like five minutes and also um add a test for it in the users dot test dot ts file and make sure you don't break the existing API",
            ]
            var longContext = context
            for (index, sample) in samples.enumerated() {
                try await Task.sleep(for: .milliseconds(2100))
                if index == 2 { longContext = DictationContext(target: .init(processID: 0, appName: "Cursor", bundleID: "com.todesktop.230313mzl4w4u92"), category: .code) }
                else if index == 0 { longContext = DictationContext(target: .init(processID: 0, appName: "Mail", bundleID: "com.apple.mail"), category: .email) }
                else { longContext = context }
                let start = ContinuousClock.now
                let result = try await provider.clean(raw: sample, context: longContext)
                let elapsed = start.duration(to: .now).components
                print(String(format: "LONG %d: %.0f ms", index + 1, Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15))
                print(result)
            }
        }
        let sorted = timings.sorted()
        if !sorted.isEmpty {
            print(String(format: "%@ latency: median %.0f ms, slowest %.0f ms", label, sorted[sorted.count / 2], sorted.last ?? 0))
        }
        print("Live cleanup: \(CleanupCases.all.count - failures)/\(CleanupCases.all.count) exact matches.")
        if failures > 0 { throw RecordingError.message("Live cleanup output did not match the expected corpus. Review before release.") }
    }
}
