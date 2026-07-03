import Foundation

/// One-shot, non-streaming completion for small tasks (router judging, prep). Uses
/// whatever key is available (Gemini → Claude).
enum FastLLM {
    static func complete(system: String, user: String, maxTokens: Int = 600) async throws -> String {
        if let k = Settings.apiKey("GEMINI_API_KEY") { return try await gemini(k, system, user, maxTokens) }
        if let k = Settings.apiKey("ANTHROPIC_API_KEY") { return try await claude(k, system, user, maxTokens) }
        throw LLMError.missingKey
    }

    private static func gemini(_ key: String, _ sys: String, _ user: String, _ maxT: Int) async throws -> String {
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent") else { throw LLMError.badURL }
        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": sys]]],
            "contents": [["role": "user", "parts": [["text": user]]]],
            "generationConfig": ["temperature": 0.2, "maxOutputTokens": maxT,
                                 "thinkingConfig": ["thinkingBudget": 0]],
        ]
        let r = try LLMHTTP.post(url, headers: ["x-goog-api-key": key], body: body)
        let d = try await LLMHTTP.send(r)
        guard let o = try JSONSerialization.jsonObject(with: d) as? [String: Any],
              let c = o["candidates"] as? [[String: Any]],
              let content = c.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else { return "" }
        return parts.compactMap { $0["text"] as? String }.joined()
    }

    private static func claude(_ key: String, _ sys: String, _ user: String, _ maxT: Int) async throws -> String {
        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else { throw LLMError.badURL }
        let body: [String: Any] = [
            "model": "claude-sonnet-4-6", "max_tokens": maxT,
            "system": sys, "messages": [["role": "user", "content": user]],
        ]
        let r = try LLMHTTP.post(url, headers: [
            "x-api-key": key,
            "anthropic-version": "2023-06-01",
        ], body: body)
        let d = try await LLMHTTP.send(r)
        guard let o = try JSONSerialization.jsonObject(with: d) as? [String: Any],
              let content = o["content"] as? [[String: Any]] else { return "" }
        return content.compactMap { $0["text"] as? String }.joined()
    }
}
