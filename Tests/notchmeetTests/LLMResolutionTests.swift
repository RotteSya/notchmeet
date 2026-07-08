import XCTest
@testable import notchmeet

/// Locks in the region-aware LLM selection (国内优先域内可直连服务) and the OpenAI 兼容
/// 请求/响应细节 — Gemini/Claude 在大陆不可直连，选错后端 = 挂到超时、答案永远出不来。
final class LLMResolutionTests: XCTestCase {
    // MARK: - resolveLLM matrix

    func testChinaPrefersDomesticOverGlobalKeys() {
        XCTAssertEqual(Settings.resolveLLM(hasGemini: true, hasClaude: true,
                                           hasDeepSeek: true, hasQwen: true, inChina: true),
                       .deepseek, "国内且有域内 key → 必须选可直连的 DeepSeek，而不是被墙的 Gemini")
        XCTAssertEqual(Settings.resolveLLM(hasGemini: true, hasClaude: false,
                                           hasDeepSeek: false, hasQwen: true, inChina: true),
                       .qwen)
    }

    func testChinaFallsBackToGlobalKeysWhenNoDomesticKey() {
        // 只有 Gemini key 的国内用户（可能自备代理）：仍然给 Gemini，而不是 mock。
        XCTAssertEqual(Settings.resolveLLM(hasGemini: true, hasClaude: false,
                                           hasDeepSeek: false, hasQwen: false, inChina: true),
                       .gemini)
    }

    func testAbroadKeepsGeminiFirstThenClaude() {
        XCTAssertEqual(Settings.resolveLLM(hasGemini: true, hasClaude: true,
                                           hasDeepSeek: true, hasQwen: true, inChina: false),
                       .gemini, "境外优先级不变：Gemini → Claude")
        XCTAssertEqual(Settings.resolveLLM(hasGemini: false, hasClaude: true,
                                           hasDeepSeek: true, hasQwen: false, inChina: false),
                       .claude)
    }

    func testAbroadUsesDomesticKeyWhenItIsTheOnlyOne() {
        XCTAssertEqual(Settings.resolveLLM(hasGemini: false, hasClaude: false,
                                           hasDeepSeek: true, hasQwen: false, inChina: false),
                       .deepseek)
    }

    func testNoKeysResolvesToNone() {
        XCTAssertEqual(Settings.resolveLLM(hasGemini: false, hasClaude: false,
                                           hasDeepSeek: false, hasQwen: false, inChina: true),
                       LLMResolution.none)
    }

    // MARK: - OpenAI 兼容 SSE delta

    func testDeltaExtractsStreamedContent() {
        let json = #"{"choices":[{"index":0,"delta":{"content":"はい、"},"finish_reason":null}]}"#
        XCTAssertEqual(OpenAIChat.delta(json), "はい、")
    }

    func testDeltaIgnoresUsageChunkAndRoleChunk() {
        // DashScope 在流末尾发 usage 块，choices 为空；首块常只有 role 无 content。
        XCTAssertNil(OpenAIChat.delta(#"{"choices":[],"usage":{"total_tokens":42}}"#))
        XCTAssertNil(OpenAIChat.delta(#"{"choices":[{"delta":{"role":"assistant"}}]}"#))
        XCTAssertNil(OpenAIChat.delta("not json"))
    }

    // MARK: - 请求体

    func testQwenBodyDisablesThinkingForFirstTokenLatency() {
        let b = OpenAIChat.body(.qwen, system: "s", user: "u", maxTokens: 512,
                                temperature: 0.5, stream: true)
        XCTAssertEqual(b["enable_thinking"] as? Bool, false,
                       "思考模式一旦默认开启，首字延迟直接破 3s 预算")
        XCTAssertEqual(b["model"] as? String, "qwen-plus")
    }

    func testBodyCarriesSystemAndUserMessagesInOrder() {
        let b = OpenAIChat.body(.deepseek, system: "SYS", user: "USR", maxTokens: 80,
                                temperature: 0.2, stream: false)
        let msgs = b["messages"] as? [[String: String]]
        XCTAssertEqual(msgs?.map { $0["role"] }, ["system", "user"])
        XCTAssertEqual(msgs?.first?["content"], "SYS")
        XCTAssertEqual(b["stream"] as? Bool, false)
        XCTAssertNil(b["enable_thinking"], "DeepSeek 不带 DashScope 特有参数")
    }
}
