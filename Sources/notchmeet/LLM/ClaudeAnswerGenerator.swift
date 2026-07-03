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
        var r = URLRequest(url: url)
        r.httpMethod = "POST"
        r.timeoutInterval = 15   // idle timeout — resets whenever a streamed byte arrives
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        r.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 512,
            "stream": true,
            "system": Prompts.system(context: req.context),
            "messages": [["role": "user", "content": Prompts.user(question: req.question, history: req.history)]],
        ]
        r.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, resp) = try await URLSession.shared.bytes(for: r)
        try httpCheck(resp)
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let json = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            if json.isEmpty { continue }
            if let t = Self.delta(json), !t.isEmpty { onDelta(t) }
        }
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
