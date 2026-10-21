import Foundation

/// Cleanup and command edits through Groq's OpenAI-compatible chat API, chosen for its very low latency.
struct GroqCleanupProvider: CleanupProvider, CommandProvider {
    /// Fastest accurate option in testing (October 2026): about 0.1 s for short clips, 0.2 s for long ones, with thinking off.
    static let defaultModel = "qwen/qwen3.8-27b"
    static let endpoint: URL = {
        var parts = URLComponents()
        parts.scheme = "https"; parts.host = "api.groq.com"; parts.path = "/openai/v1/chat/completions"
        return parts.url ?? URL(fileURLWithPath: "/invalid-endpoint")
    }()
    let authorize: @Sendable () async throws -> String
    let transport: any CloudTransport
    let model: String
    let timeout: TimeInterval
    var serviceName: String? { "Groq" }
    let reasoningEffort: String?
    init(model: String = GroqCleanupProvider.defaultModel, timeout: TimeInterval = 1.5,
         reasoningEffort: String? = nil,
         authorize: @escaping @Sendable () async throws -> String,
         transport: any CloudTransport = URLSessionCloudTransport.shared) {
        self.model = model; self.timeout = timeout; self.authorize = authorize; self.transport = transport
        self.reasoningEffort = reasoningEffort ?? Self.fastestReasoning(for: model)
    }
    /// Thinking models are slow for a job this simple: turn thinking off where the model allows it,
    /// otherwise keep it as short as possible.
    static func fastestReasoning(for model: String) -> String? {
        let name = model.lowercased()
        if name.contains("gpt-oss") { return "low" }
        if name.contains("qwen3") { return "none" }
        return nil
    }

    func clean(raw: String, context: DictationContext) async throws -> String {
        guard CleanupPrompt.shouldClean(raw, context: context) else { return raw }
        let output = try await request(system: CleanupPrompt.system,
                                       user: try CleanupPrompt.userMessage(raw: raw, context: context),
                                       outputEstimate: raw.utf8.count)
        return CleanupPrompt.sanitize(output)
    }
    func edit(selection: String, instruction: String, context: DictationContext) async throws -> String {
        try await request(system: CommandPrompt.system,
                          user: CommandPrompt.user(selection: selection, instruction: instruction, context: context),
                          outputEstimate: selection.utf8.count + instruction.utf8.count)
    }
    /// Each Groq model has its own per-minute limit, so a rate-limited request is retried once on another model.
    static func fallback(for model: String) -> String? {
        let fast = ["qwen/qwen3.8-27b", "openai/gpt-oss-120b"]
        guard let index = fast.firstIndex(of: model.lowercased()) else { return nil }
        return fast[(index + 1) % fast.count]
    }
    private func request(system: String, user: String, outputEstimate: Int) async throws -> String {
        do {
            return try await request(model: model, effort: reasoningEffort, system: system, user: user, outputEstimate: outputEstimate)
        } catch CloudError.http(429) {
            guard let other = Self.fallback(for: model) else { throw CloudError.http(429) }
            return try await request(model: other, effort: Self.fastestReasoning(for: other),
                                     system: system, user: user, outputEstimate: outputEstimate)
        }
    }
    private func request(model: String, effort: String?, system: String, user: String, outputEstimate: Int) async throws -> String {
        let key = try await authorize()
        try Task.checkCancellation()
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = max(0.2, timeout)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let answerBudget = min(8192, max(512, (outputEstimate + 1) / 2))
        var payload: [String: Any] = [
            "model": model, "temperature": 0,
            "max_completion_tokens": answerBudget + (effort != nil && effort != "none" ? 1024 : 0),
            "messages": [["role": "system", "content": system], ["role": "user", "content": user]]
        ]
        if let effort { payload["reasoning_effort"] = effort }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, status) = try await transport.send(request)
        guard (200..<300).contains(status) else { throw CloudError.http(status) }
        struct Response: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable { let content: String? }
                let message: Message
                let finish_reason: String?
            }
            let choices: [Choice]
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data), let choice = response.choices.first,
              choice.finish_reason != "length" else { throw CloudError.invalidResponse }
        let text = (choice.message.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw CloudError.invalidResponse }
        return text
    }
}
