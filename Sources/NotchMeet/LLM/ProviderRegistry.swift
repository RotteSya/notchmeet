import Foundation

/// Selects concrete STT / LLM providers from available keys (Keychain → env).
/// Falls back to mocks so the app always runs (PLAN §5 provider abstraction).
enum ProviderRegistry {
    /// 每个 resolution 对应的 key 名——`makeGeneratorChain` 与 `FastLLM` 共用。
    static func keyName(for resolution: LLMResolution) -> String? {
        switch resolution {
        case .gemini:   return "GEMINI_API_KEY"
        case .claude:   return "ANTHROPIC_API_KEY"
        case .deepseek: return "DEEPSEEK_API_KEY"
        case .qwen:     return "DASHSCOPE_API_KEY"
        case .none:     return nil
        }
    }

    private static func generator(for resolution: LLMResolution, key: String) -> AnswerGenerator? {
        switch resolution {
        case .gemini:   return GeminiAnswerGenerator(apiKey: key)
        case .claude:   return ClaudeAnswerGenerator(apiKey: key)
        case .deepseek: return OpenAIChatAnswerGenerator(endpoint: .deepseek, apiKey: key)
        case .qwen:     return OpenAIChatAnswerGenerator(endpoint: .qwen, apiKey: key)
        case .none:     return nil
        }
    }

    /// 主选 provider 排头，其余持有 key 的按固定顺序顺延——供运行时降级。
    /// 国内优先域内可直连服务的顺序由 `llmResolution()` 决定，这里只负责补齐候补。
    static func makeGeneratorChain() -> (generators: [AnswerGenerator], names: [String]) {
        let primary = llmResolution()
        let order: [LLMResolution] = [.qwen, .deepseek, .gemini, .claude]
        let ordered = [primary] + order.filter { $0 != primary }
        var generators: [AnswerGenerator] = []
        var names: [String] = []
        for resolution in ordered {
            guard let keyName = keyName(for: resolution),
                  let key = Settings.apiKey(keyName), !key.isEmpty,
                  let gen = generator(for: resolution, key: key) else { continue }
            generators.append(gen)
            names.append(String(describing: resolution))
        }
        return (generators, names)
    }

    static func makeGenerator() -> AnswerGenerator {
        let (generators, names) = makeGeneratorChain()
        guard !generators.isEmpty else {
            // Keychain 在 resolve 与 build 之间被清空（或 ACL 被拒）也会落到这里——
            // 旧实现在这一步 `!` 强制解包，等于面试中崩溃。
            // 注意这里**不是** MockAnswerGenerator（审计 R6）：mock 的流利假答案在
            // 刘海上与真答案毫无区别，真实会话里必须显式报「没有可用的 API 密钥」。
            NSLog("[provider] no usable LLM key — live turns will surface missingKey")
            return UnconfiguredAnswerGenerator()
        }
        NSLog("[provider] LLM = %@ (+%d fallback)", names[0], generators.count - 1)
        guard generators.count > 1 else { return generators[0] }
        return FallbackAnswerGenerator(chain: generators, names: names)
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

    /// 当前解析结果在国内网络下是否被墙（只有 Gemini/Claude key、没有域内 key）。
    /// 自检与就绪判定用它给出「无法直连」警告。
    static func llmChinaBlocked() -> Bool {
        Settings.llmBlockedInChina(llmResolution(), inChina: Settings.isLikelyInChina())
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
            let locale = Settings.interviewLanguage.appleLocaleID
            NSLog("[provider] STT = Apple on-device (%@)", locale)
            return AppleSpeechSttClient(localeID: locale)
        case .deepgram:
            guard let key = Settings.apiKey("DEEPGRAM_API_KEY"), !key.isEmpty else {
                // resolve 与 build 之间 key 被清除 / Keychain ACL 被拒 →
                // 旧实现在这里强制解包崩溃。降级为 mock，上层照常提示无可用引擎。
                NSLog("[provider] Deepgram key vanished between resolve and build — mock STT")
                return MockSttClient()
            }
            NSLog("[provider] STT = Deepgram")
            return DeepgramSttClient(apiKey: key,
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
