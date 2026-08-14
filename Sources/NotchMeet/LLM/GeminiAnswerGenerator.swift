import Foundation

/// Gemini streaming generator (streamGenerateContent SSE). Fast path for the 3s SLA.
final class GeminiAnswerGenerator: AnswerGenerator {
    private let apiKey: String
    private let model: String

    init(apiKey: String, model: String = GeminiEndpoint.model) {
        self.apiKey = apiKey
        self.model = model
    }

    func generate(_ req: GenRequest, epoch: Int, onDelta: @escaping (String) -> Void) async throws {
        let urlStr = "\(GeminiEndpoint.host)/\(model):streamGenerateContent?alt=sse"
        guard let url = URL(string: urlStr) else { throw LLMError.badURL }
        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": Prompts.system(language: req.language)]]],
            "contents": [["role": "user", "parts": [["text": Prompts.user(question: req.question, history: req.history, context: req.context, language: req.language)]]]],
            // thinkingBudget:0 disables 2.5-Flash "thinking" — critical for first-token latency.
            "generationConfig": ["temperature": 0.5, "maxOutputTokens": 512,
                                 "thinkingConfig": ["thinkingBudget": 0]],
        ]
        let request = try LLMHTTP.post(url, headers: GeminiEndpoint.headers(apiKey), body: body)
        try await LLMHTTP.streamSSE(request, extract: Self.text, onDelta: onDelta)
    }

    private static func text(_ json: String) -> String? {
        guard let d = json.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let cands = o["candidates"] as? [[String: Any]],
              let content = cands.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else { return nil }
        return parts.compactMap { $0["text"] as? String }.joined()
    }
}
