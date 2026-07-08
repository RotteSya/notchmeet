import Foundation

/// Selects concrete STT / LLM providers from available keys (Keychain → env).
/// Falls back to mocks so the app always runs (PLAN §5 provider abstraction).
enum ProviderRegistry {
    static func makeGenerator() -> AnswerGenerator {
        switch llmResolution() {
        case .gemini:
            NSLog("[provider] LLM = Gemini")
            return GeminiAnswerGenerator(apiKey: Settings.apiKey("GEMINI_API_KEY")!)
        case .claude:
            NSLog("[provider] LLM = Claude")
            return ClaudeAnswerGenerator(apiKey: Settings.apiKey("ANTHROPIC_API_KEY")!)
        case .deepseek:
            NSLog("[provider] LLM = DeepSeek")
            return OpenAIChatAnswerGenerator(endpoint: .deepseek, apiKey: Settings.apiKey("DEEPSEEK_API_KEY")!)
        case .qwen:
            NSLog("[provider] LLM = Qwen (DashScope)")
            return OpenAIChatAnswerGenerator(endpoint: .qwen, apiKey: Settings.apiKey("DASHSCOPE_API_KEY")!)
        case .none:
            NSLog("[provider] no LLM key — using mock generator")
            return MockAnswerGenerator()
        }
    }

    /// The LLM the app WILL use, given available keys + region. Single source of truth
    /// shared by `makeGenerator()`, `FastLLM`, consent and health so they never disagree
    /// (same pattern as `sttResolution`). 国内优先域内可直连服务，见 `Settings.resolveLLM`.
    static func llmResolution() -> LLMResolution {
        Settings.resolveLLM(hasGemini: Settings.apiKey("GEMINI_API_KEY") != nil,
                            hasClaude: Settings.apiKey("ANTHROPIC_API_KEY") != nil,
                            hasDeepSeek: Settings.apiKey("DEEPSEEK_API_KEY") != nil,
                            hasQwen: Settings.apiKey("DASHSCOPE_API_KEY") != nil,
                            inChina: Settings.isLikelyInChina())
    }

    /// Display name for consent / health / settings; nil = no LLM configured.
    static func llmDisplayName() -> String? {
        switch llmResolution() {
        case .gemini: return "Gemini"
        case .claude: return "Claude"
        case .deepseek: return OpenAIChatEndpoint.deepseek.display
        case .qwen: return OpenAIChatEndpoint.qwen.display
        case .none: return nil
        }
    }

    /// The STT engine the app WILL use, given pref (incl. FI_STT_ENGINE), region, and key.
    /// Single source of truth shared by `makeStt()` and the launch gate so they never disagree.
    static func sttResolution() -> SttResolution {
        Settings.resolveStt(pref: sttEnginePreference(),
                            inChina: Settings.isLikelyInChina(),
                            hasDeepgramKey: Settings.apiKey("DEEPGRAM_API_KEY") != nil)
    }

    static func makeStt() -> SttClient {
        switch sttResolution() {
        case .apple:
            NSLog("[provider] STT = Apple on-device (ja-JP)")
            return AppleSpeechSttClient()
        case .deepgram:
            NSLog("[provider] STT = Deepgram")
            return DeepgramSttClient(apiKey: Settings.apiKey("DEEPGRAM_API_KEY")!,
                                     language: Settings.interviewLanguage.deepgramCode)
        case .mock:
            NSLog("[provider] no STT — using mock STT")
            return MockSttClient()
        }
    }

    /// 调试覆盖：`FI_STT_ENGINE=auto|deepgram|apple` 强制引擎（便于在非国内机器上验证 Apple 路径）。
    private static func sttEnginePreference() -> SttEngine {
        if let raw = ProcessInfo.processInfo.environment["FI_STT_ENGINE"],
           let e = SttEngine(rawValue: raw) { return e }
        return Settings.sttEngine
    }
}
