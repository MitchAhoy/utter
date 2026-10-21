import Foundation

/// Groq's daily request allowance for one model, as reported in the headers of the last reply.
struct GroqUsageSnapshot: Codable, Sendable, Equatable {
    let model: String
    let limit: Int
    let remaining: Int
    /// Seconds from `updated` until the allowance is back to full (Groq refills gradually).
    let secondsUntilFull: TimeInterval
    let updated: Date

    var fullAt: Date { updated.addingTimeInterval(secondsUntilFull) }

    /// Remaining now, assuming the steady refill Groq's reset header describes.
    func estimatedRemaining(at now: Date = Date()) -> Int {
        guard remaining < limit, secondsUntilFull > 0 else { return remaining }
        let elapsed = max(0, now.timeIntervalSince(updated))
        let refilled = Double(limit - remaining) * min(1, elapsed / secondsUntilFull)
        return min(limit, remaining + Int(refilled))
    }

    var title: String {
        let short = model.split(separator: "/").last.map(String.init) ?? model
        return model.lowercased().contains("whisper") ? "Speech to text" : "Cleanup · \(short)"
    }

    /// True when few enough requests are left that the user should know before they run out.
    func isLow(at now: Date = Date()) -> Bool {
        estimatedRemaining(at: now) <= max(25, limit / 10)
    }
}

/// Keeps the latest Groq allowance per model. Fed from response headers, so it costs no extra requests.
final class GroqUsageStore: @unchecked Sendable {
    static let shared = GroqUsageStore()
    private let lock = NSLock()
    private let defaults: UserDefaults
    private let key = "groqUsage"
    private var snapshots: [String: GroqUsageSnapshot]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        snapshots = defaults.data(forKey: key)
            .flatMap { try? JSONDecoder().decode([String: GroqUsageSnapshot].self, from: $0) } ?? [:]
    }

    func record(model: String, response: HTTPURLResponse, now: Date = Date()) {
        guard let limit = response.value(forHTTPHeaderField: "x-ratelimit-limit-requests").flatMap(Int.init),
              let remaining = response.value(forHTTPHeaderField: "x-ratelimit-remaining-requests").flatMap(Int.init) else { return }
        let reset = response.value(forHTTPHeaderField: "x-ratelimit-reset-requests").flatMap(Self.seconds) ?? 0
        let snapshot = GroqUsageSnapshot(model: model, limit: limit, remaining: remaining, secondsUntilFull: reset, updated: now)
        lock.withLock {
            snapshots[model] = snapshot
            if let data = try? JSONEncoder().encode(snapshots) { defaults.set(data, forKey: key) }
        }
    }

    /// Speech first, then cleanup models, most recently used first.
    func all() -> [GroqUsageSnapshot] {
        lock.withLock { Array(snapshots.values) }.sorted {
            let speech = ($0.title == "Speech to text", $1.title == "Speech to text")
            if speech.0 != speech.1 { return speech.0 }
            return $0.updated > $1.updated
        }
    }

    /// Parses Groq durations such as "3h7m12s", "47.631s", "1m26.4s" or "577ms".
    static func seconds(_ text: String) -> TimeInterval? {
        var total: TimeInterval = 0
        var number = ""
        var matched = false
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character.isNumber || character == "." { number.append(character); index = text.index(after: index); continue }
            guard let value = Double(number) else { return nil }
            let rest = text[index...]
            if rest.hasPrefix("ms") { total += value / 1000; index = text.index(index, offsetBy: 2) }
            else if character == "h" { total += value * 3600; index = text.index(after: index) }
            else if character == "m" { total += value * 60; index = text.index(after: index) }
            else if character == "s" { total += value; index = text.index(after: index) }
            else { return nil }
            number = ""
            matched = true
        }
        return matched && number.isEmpty ? total : nil
    }

    static func describe(_ interval: TimeInterval) -> String {
        let minutes = Int((interval / 60).rounded(.up))
        if minutes < 60 { return "\(max(1, minutes))m" }
        return minutes % 60 == 0 ? "\(minutes / 60)h" : "\(minutes / 60)h \(minutes % 60)m"
    }
}
