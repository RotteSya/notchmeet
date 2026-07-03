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
    static func streamSSE(_ req: URLRequest,
                          extract: @escaping (String) -> String?,
                          onDelta: @escaping (String) -> Void) async throws {
        let (bytes, resp) = try await URLSession.shared.bytes(for: req)
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
    static func send(_ req: URLRequest) async throws -> Data {
        let (d, resp) = try await URLSession.shared.data(for: req)
        try httpCheck(resp)
        return d
    }
}
