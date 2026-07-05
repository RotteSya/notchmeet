import Foundation

/// Selects concrete STT / LLM providers from available keys (Keychain → env).
/// Falls back to mocks so the app always runs (PLAN §5 provider abstraction).
enum ProviderRegistry {
    static func makeGenerator() -> AnswerGenerator {
        if let k = Settings.apiKey("GEMINI_API_KEY") {
            NSLog("[provider] LLM = Gemini")
            return GeminiAnswerGenerator(apiKey: k)
        }
        if let k = Settings.apiKey("ANTHROPIC_API_KEY") {
            NSLog("[provider] LLM = Claude")
            return ClaudeAnswerGenerator(apiKey: k)
        }
        NSLog("[provider] no LLM key — using mock generator")
        return MockAnswerGenerator()
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
