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

    static func makeStt() -> SttClient {
        if let k = Settings.apiKey("DEEPGRAM_API_KEY") {
            NSLog("[provider] STT = Deepgram")
            return DeepgramSttClient(apiKey: k, language: Settings.interviewLanguage.deepgramCode)
        }
        NSLog("[provider] no Deepgram key — using mock STT")
        return MockSttClient()
    }
}
