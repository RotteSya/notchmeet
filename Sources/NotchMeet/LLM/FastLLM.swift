import Foundation

/// One-shot, non-streaming completion for small tasks (router judging, prep). Follows
/// `ProviderRegistry.llmResolution()` so the router always talks to the same (reachable)
/// backend as live generation — 国内即域内服务，避免 router 卡在被墙端点上超时。
enum FastLLM {
    static func complete(system: String, user: String, maxTokens: Int = 600) async throws -> String {
        switch ProviderRegistry.llmResolution() {
        case .gemini:
            return try await gemini(Settings.apiKey("GEMINI_API_KEY")!, system, user, maxTokens)
        case .claude:
            return try await claude(Settings.apiKey("ANTHROPIC_API_KEY")!, system, user, maxTokens)
        case .deepseek:
            return try await OpenAIChat.complete(.deepseek, apiKey: Settings.apiKey("DEEPSEEK_API_KEY")!,
                                                 system: system, user: user, maxTokens: maxTokens)
        case .qwen:
            return try await OpenAIChat.complete(.qwen, apiKey: Settings.apiKey("DASHSCOPE_API_KEY")!,
                                                 system: system, user: user, maxTokens: maxTokens)
        case .none:
            throw LLMError.missingKey
        }
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
