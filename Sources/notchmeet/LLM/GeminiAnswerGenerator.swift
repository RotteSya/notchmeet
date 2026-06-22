import Foundation

/// Gemini streaming generator (streamGenerateContent SSE). Fast path for the 3s SLA.
final class GeminiAnswerGenerator: AnswerGenerator {
    private let apiKey: String
    private let model: String

    init(apiKey: String, model: String = "gemini-2.5-flash") {
        self.apiKey = apiKey
        self.model = model
    }

    func generate(_ req: GenRequest, epoch: Int, onDelta: @escaping (String) -> Void) async throws {
        let urlStr = "https://generativelanguage.googleapis.com/v1beta/models/\(model):streamGenerateContent?alt=sse&key=\(apiKey)"
        guard let url = URL(string: urlStr) else { throw LLMError.badURL }

        var r = URLRequest(url: url)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": Prompts.system(context: req.context)]]],
            "contents": [["role": "user", "parts": [["text": Prompts.user(question: req.question, history: req.history)]]]],
            // thinkingBudget:0 disables 2.5-Flash "thinking" — critical for first-token latency.
            "generationConfig": ["temperature": 0.5, "maxOutputTokens": 512,
                                 "thinkingConfig": ["thinkingBudget": 0]],
        ]
        r.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, resp) = try await URLSession.shared.bytes(for: r)
        try httpCheck(resp)
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let json = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            if json.isEmpty || json == "[DONE]" { continue }
            if let text = Self.text(json), !text.isEmpty { onDelta(text) }
        }
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
