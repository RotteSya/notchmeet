import Foundation

/// Gemini / Claude 的端点与模型描述，与 `OpenAIChatEndpoint` 同构。
///
/// 在此之前这些常量各写两份（生成器一份、FastLLM 一份）：换模型要改两处，漏一处
/// 就会出现「路由用 A 模型、生成用 B 模型」——更贵、更慢，而且从表现上几乎看不出来。
enum GeminiEndpoint {
    static let model = "gemini-2.5-flash"
    static let host = "https://generativelanguage.googleapis.com/v1beta/models"

    /// 流式（live 生成）。
    static var streamURL: URL? { URL(string: "\(host)/\(model):streamGenerateContent?alt=sse") }
    /// 一次性（router / prep）。
    static var completeURL: URL? { URL(string: "\(host)/\(model):generateContent") }

    static func headers(_ apiKey: String) -> [String: String] { ["x-goog-api-key": apiKey] }
}

enum ClaudeEndpoint {
    static let model = "claude-sonnet-4-6"
    static let apiVersion = "2023-06-01"

    static var url: URL? { URL(string: "https://api.anthropic.com/v1/messages") }

    static func headers(_ apiKey: String) -> [String: String] {
        ["x-api-key": apiKey, "anthropic-version": apiVersion]
    }
}
