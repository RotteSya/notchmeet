import Foundation

/// One-shot, non-streaming completion for small tasks (router judging, prep). Follows
/// `ProviderRegistry.llmResolution()` so the router always talks to the same (reachable)
/// backend as live generation — 国内即域内服务，避免 router 卡在被墙端点上超时。
enum FastLLM {
    static func complete(system: String, user: String, maxTokens: Int = 600) async throws -> String {
        // 一次性解析 (resolution, key)。旧实现先由 llmResolution() 判断 key 存在，
        // 再各自独立取值并 `!` 强制解包：两次读 Keychain 之间 key 被清除，或重签名后
        // ACL 弹框被用户点「拒绝」，第二次读返回 nil —— 面试中直接崩溃。
        let resolution = ProviderRegistry.llmResolution()
        guard let keyName = ProviderRegistry.keyName(for: resolution),
              let key = Settings.apiKey(keyName), !key.isEmpty else {
            throw LLMError.missingKey
        }
        switch resolution {
        case .gemini:
            return try await gemini(key, system, user, maxTokens)
        case .claude:
            return try await claude(key, system, user, maxTokens)
        case .deepseek:
            return try await OpenAIChat.complete(.deepseek, apiKey: key,
                                                 system: system, user: user, maxTokens: maxTokens)
        case .qwen:
            return try await OpenAIChat.complete(.qwen, apiKey: key,
                                                 system: system, user: user, maxTokens: maxTokens)
        case .none:
            throw LLMError.missingKey
        }
    }

    private static func gemini(_ key: String, _ sys: String, _ user: String, _ maxT: Int) async throws -> String {
        guard let url = GeminiEndpoint.completeURL else { throw LLMError.badURL }
        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": sys]]],
            "contents": [["role": "user", "parts": [["text": user]]]],
            "generationConfig": ["temperature": 0.2, "maxOutputTokens": maxT,
                                 "thinkingConfig": ["thinkingBudget": 0]],
        ]
        let r = try LLMHTTP.post(url, headers: GeminiEndpoint.headers(key), body: body)
        let d = try await LLMHTTP.send(r)
        guard let o = try JSONSerialization.jsonObject(with: d) as? [String: Any],
              let c = o["candidates"] as? [[String: Any]],
              let content = c.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else { return "" }
        return parts.compactMap { $0["text"] as? String }.joined()
    }

    private static func claude(_ key: String, _ sys: String, _ user: String, _ maxT: Int) async throws -> String {
        guard let url = ClaudeEndpoint.url else { throw LLMError.badURL }
        let body: [String: Any] = [
            "model": ClaudeEndpoint.model, "max_tokens": maxT,
            "system": sys, "messages": [["role": "user", "content": user]],
        ]
        let r = try LLMHTTP.post(url, headers: ClaudeEndpoint.headers(key), body: body)
        let d = try await LLMHTTP.send(r)
        guard let o = try JSONSerialization.jsonObject(with: d) as? [String: Any],
              let content = o["content"] as? [[String: Any]] else { return "" }
        return content.compactMap { $0["text"] as? String }.joined()
    }
}
