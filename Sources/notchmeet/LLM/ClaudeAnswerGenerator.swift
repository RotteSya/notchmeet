import Foundation

/// Anthropic Messages streaming generator. Quality path (PLAN: 日语质量优先).
final class ClaudeAnswerGenerator: AnswerGenerator {
    private let apiKey: String
    private let model: String

    init(apiKey: String, model: String = "claude-sonnet-4-6") {
        self.apiKey = apiKey
        self.model = model
    }

    func generate(_ req: GenRequest, epoch: Int, onDelta: @escaping (String) -> Void) async throws {
        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else { throw LLMError.badURL }
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 512,
            "stream": true,
            "system": Prompts.system(context: req.context),
            "messages": [["role": "user", "content": Prompts.user(question: req.question, history: req.history)]],
        ]
        let request = try LLMHTTP.post(url, headers: [
            "x-api-key": apiKey,
            "anthropic-version": "2023-06-01",
        ], body: body)
        try await LLMHTTP.streamSSE(request, extract: Self.delta, onDelta: onDelta)
    }

    private static func delta(_ json: String) -> String? {
        guard let d = json.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        if o["type"] as? String == "content_block_delta",
           let delta = o["delta"] as? [String: Any],
           let t = delta["text"] as? String {
            return t
        }
        return nil
    }
}
