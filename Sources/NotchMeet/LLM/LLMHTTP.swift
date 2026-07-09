import Foundation

/// Shared HTTP plumbing for the LLM providers: request building, the latency-bound
/// timeout, and the SSE `data:` streaming loop. Each provider supplies its own URL,
/// auth header, request body, and delta-extraction closure — this only removes the
/// boilerplate they all repeated (and keeps the timeout consistent across them).
enum LLMHTTP {
    /// Router/prep and live generation are latency-bound; the default 60s URLSession
    /// timeout contradicts the 3s SLA story. For streaming this is an *idle* timeout —
    /// it resets whenever a byte arrives, so it never truncates a healthy long answer.
    static let timeout: TimeInterval = 15

    /// 域内可直连端点（DeepSeek / Qwen）走这个 session：它**显式忽略系统代理**，直连出口。
    /// 背景：国内用户为开 Google Meet 常挂**全局模式**的梯子，会把本可直连的 `api.deepseek.com` /
    /// `dashscope.aliyuncs.com` 也带出境，跨境握手 + 首 token 直接破 3s 预算（用户报的「反应很慢」）。
    /// 境外端点（Gemini / Claude）**不**用它——那些正是靠系统代理才能访问，见 `bypassSystemProxy`。
    /// 局限：仅对「系统代理模式」的梯子有效；TUN / 透明代理在 IP 层劫持，URLSession 层无法绕过
    /// （那种情况只能让用户在梯子里给域内域名配直连规则）。
    static let directSession: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.connectionProxyDictionary = [:]   // 空字典 = 不使用任何代理（nil 才是「沿用系统代理」）
        return URLSession(configuration: cfg)
    }()

    static func post(_ url: URL, headers: [String: String], body: [String: Any]) throws -> URLRequest {
        var r = URLRequest(url: url)
        r.httpMethod = "POST"
        r.timeoutInterval = timeout
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        r.httpBody = try JSONSerialization.data(withJSONObject: body)
        return r
    }

    /// Stream an SSE response, emitting each non-empty chunk `extract` pulls from a `data:` line.
    /// `bypassSystemProxy: true` sends via `directSession` (域内端点直连，绕过全局梯子)；默认 false
    /// 走 `.shared`（境外端点靠系统代理访问）。
    static func streamSSE(_ req: URLRequest,
                          bypassSystemProxy: Bool = false,
                          extract: @escaping (String) -> String?,
                          onDelta: @escaping (String) -> Void) async throws {
        let session = bypassSystemProxy ? directSession : .shared
        let (bytes, resp) = try await session.bytes(for: req)
        try httpCheck(resp)
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let json = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            if json.isEmpty || json == "[DONE]" { continue }
            if let t = extract(json), !t.isEmpty { onDelta(t) }
        }
    }

    /// One-shot POST returning the response body after a 2xx check.
    /// `bypassSystemProxy: true` → `directSession`（域内端点直连）；默认走 `.shared`。
    static func send(_ req: URLRequest, bypassSystemProxy: Bool = false) async throws -> Data {
        let session = bypassSystemProxy ? directSession : .shared
        let (d, resp) = try await session.data(for: req)
        try httpCheck(resp)
        return d
    }
}
