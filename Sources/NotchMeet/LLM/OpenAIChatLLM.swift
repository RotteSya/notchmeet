import Foundation

/// OpenAI Chat Completions 兼容后端（国内可直连）。一个实现覆盖 DeepSeek 与通义千问
/// （DashScope compatible-mode）——两者请求/流式响应同构，仅 URL／模型／鉴权不同。
/// 背景：Gemini/Claude 端点在中国大陆不可直连（同 Deepgram 的跨境问题，见
/// docs/superpowers/specs/2026-07-05-apple-ondevice-stt-design.md）；live 生成与路由
/// 在国内必须走域内端点，3s SLA 才有可能成立。
struct OpenAIChatEndpoint {
    let display: String          // consent／自检中展示的提供方名
    let url: URL
    let model: String
    let extraBody: [String: Any] // 提供方特有参数（如 DashScope 的 enable_thinking）

    static let deepseek = OpenAIChatEndpoint(
        display: "DeepSeek",
        url: URL(string: "https://api.deepseek.com/chat/completions")!,
        model: "deepseek-chat",
        extraBody: [:]
    )
    // 显式关闭思考模式：混合思考模型一旦默认漂移到思考态，首字延迟直接破 3s 预算。
    static let qwen = OpenAIChatEndpoint(
        display: "Qwen",
        url: URL(string: "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions")!,
        model: "qwen-plus",
        extraBody: ["enable_thinking": false]
    )
}

/// 请求组装 + 响应解析（流式/一次性共用），供生成器与 FastLLM 复用。
enum OpenAIChat {
    static func body(_ ep: OpenAIChatEndpoint, system: String, user: String,
                     maxTokens: Int, temperature: Double, stream: Bool) -> [String: Any] {
        var b: [String: Any] = [
            "model": ep.model,
            "max_tokens": maxTokens,
            "temperature": temperature,
            "stream": stream,
            "messages": [["role": "system", "content": system],
                         ["role": "user", "content": user]],
        ]
        for (k, v) in ep.extraBody { b[k] = v }
        return b
    }

    static func request(_ ep: OpenAIChatEndpoint, apiKey: String, body: [String: Any]) throws -> URLRequest {
        try LLMHTTP.post(ep.url, headers: ["Authorization": "Bearer \(apiKey)"], body: body)
    }

    /// 流式 delta：`choices[0].delta.content`。DashScope 末尾的 usage 块 choices 为空 → nil。
    static func delta(_ json: String) -> String? {
        guard let d = json.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let choices = o["choices"] as? [[String: Any]],
              let delta = choices.first?["delta"] as? [String: Any],
              let t = delta["content"] as? String else { return nil }
        return t
    }

    /// 一次性补全（router／prep 用，对应 FastLLM 语义）。
    static func complete(_ ep: OpenAIChatEndpoint, apiKey: String,
                         system: String, user: String, maxTokens: Int) async throws -> String {
        let r = try request(ep, apiKey: apiKey,
                            body: body(ep, system: system, user: user,
                                       maxTokens: maxTokens, temperature: 0.2, stream: false))
        // 域内端点直连，绕过全局梯子（见 LLMHTTP.directSession）。
        let d = try await LLMHTTP.send(r, bypassSystemProxy: true)
        guard let o = try JSONSerialization.jsonObject(with: d) as? [String: Any],
              let choices = o["choices"] as? [[String: Any]],
              let msg = choices.first?["message"] as? [String: Any] else { return "" }
        return (msg["content"] as? String) ?? ""
    }
}

/// OpenAI 兼容 SSE 流式回答生成器，与 Gemini/Claude 生成器同构（PLAN §5 provider 抽象）。
final class OpenAIChatAnswerGenerator: AnswerGenerator {
    private let endpoint: OpenAIChatEndpoint
    private let apiKey: String

    init(endpoint: OpenAIChatEndpoint, apiKey: String) {
        self.endpoint = endpoint
        self.apiKey = apiKey
    }

    func generate(_ req: GenRequest, epoch: Int, onDelta: @escaping (String) -> Void) async throws {
        let body = OpenAIChat.body(endpoint,
                                   system: Prompts.system(context: req.context),
                                   user: Prompts.user(question: req.question, history: req.history),
                                   maxTokens: 512, temperature: 0.5, stream: true)
        let request = try OpenAIChat.request(endpoint, apiKey: apiKey, body: body)
        // 域内端点直连，绕过全局梯子（见 LLMHTTP.directSession）。
        try await LLMHTTP.streamSSE(request, bypassSystemProxy: true,
                                    extract: OpenAIChat.delta, onDelta: onDelta)
    }
}
