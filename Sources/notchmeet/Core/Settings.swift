import Foundation

/// 用户选择的 STT 引擎。`auto` 由 `Settings.resolveStt` 结合地区/Key 决定实际引擎。
enum SttEngine: String, CaseIterable {
    case auto
    case deepgram
    case apple
}

/// `makeStt` 实际应实例化的客户端。
enum SttResolution: Equatable {
    case apple
    case deepgram
    case mock
}

/// `makeGenerator`／`FastLLM` 实际应使用的 LLM 后端；`Settings.resolveLLM` 是唯一的
/// 选择逻辑（纯函数，便于测试），与 `SttResolution` 同一模式。
enum LLMResolution: Equatable {
    case gemini
    case claude
    case deepseek
    case qwen
    case none
}

/// Runtime settings + key resolution. Keys come from Keychain first, then env (dev).
enum Settings {
    /// The product currently supports Japanese interviews. This is deliberately
    /// independent from the Chinese/Japanese chrome selected by the user.
    static let interviewLanguage: InterviewLanguage = .japanese

    /// First-launch onboarding completed. Non-secret UI state → UserDefaults
    /// (API keys stay in Keychain; see `Secrets`).
    static var onboarded: Bool {
        get { UserDefaults.standard.bool(forKey: "nm_onboarded") }
        set { UserDefaults.standard.set(newValue, forKey: "nm_onboarded") }
    }

    /// Bump when the recording data-use disclosure materially changes, so already-consented
    /// users are re-prompted with the new terms before the next recording.
    static let currentConsentVersion = 1

    /// Highest data-use disclosure version the user has explicitly agreed to (0 = never).
    /// Gates the first live recording — nothing is captured/uploaded until the user has
    /// seen, and accepted, exactly what leaves the device (see `AppController`).
    static var recordingConsentVersion: Int {
        get { UserDefaults.standard.integer(forKey: "nm_consent_version") }
        set { UserDefaults.standard.set(newValue, forKey: "nm_consent_version") }
    }

    /// Whether the user's resume facts + interview script may be sent to the cloud LLM as
    /// grounding (and used for LLM-based question routing). Default ON — the product grounds
    /// answers on this context — but it is disclosed in consent and toggleable in Settings.
    static var sendContextToLLM: Bool {
        get { UserDefaults.standard.object(forKey: "nm_send_context") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "nm_send_context") }
    }

    /// Bundle ID of the single app whose output audio is captured. `nil` = auto-detect the
    /// active call app (see `AudioTargetResolver`). Persisted so the choice survives relaunch.
    /// Data-minimization: we tap ONE app, never all system audio.
    static var captureTargetBundleID: String? {
        get { UserDefaults.standard.string(forKey: "nm_capture_bundle_id") }
        set {
            if let v = newValue, !v.isEmpty { UserDefaults.standard.set(v, forKey: "nm_capture_bundle_id") }
            else { UserDefaults.standard.removeObject(forKey: "nm_capture_bundle_id") }
        }
    }

    /// STT 引擎偏好（UI 三段选择器）。默认 `auto`。
    static var sttEngine: SttEngine {
        get { SttEngine(rawValue: UserDefaults.standard.string(forKey: "nm_stt_engine") ?? "") ?? .auto }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "nm_stt_engine") }
    }

    /// 纯选择逻辑（无副作用，便于测试）：
    /// - `.apple` → 总是 Apple 本地（无需任何 Key）。
    /// - `.deepgram` → 有 Key 用 Deepgram，否则 Mock。
    /// - `.auto` → 国内用 Apple；否则有 Key 用 Deepgram，再否则 Mock。
    static func resolveStt(pref: SttEngine, inChina: Bool, hasDeepgramKey: Bool) -> SttResolution {
        switch pref {
        case .apple:
            return .apple
        case .deepgram:
            return hasDeepgramKey ? .deepgram : .mock
        case .auto:
            if inChina { return .apple }
            return hasDeepgramKey ? .deepgram : .mock
        }
    }

    /// 按地区排序的 LLM 选择（无副作用）：国内优先可直连的域内服务（Qwen → DeepSeek）——
    /// Gemini/Claude 端点在大陆不可直连，只作垫底（用户可能自备代理）；境外维持原有
    /// Gemini → Claude 优先，域内服务作补充。
    /// 域内先 Qwen：DeepSeek 官方 API 的首 token 延迟第三方实测常态数秒级
    /// （aimultiple 2026 基准：Q&A 首 token 7–8s），对「3s 内出首句」是硬风险；
    /// 千问 DashScope 走阿里云域内节点，同级模型 TTFT 亚秒级。
    static func resolveLLM(hasGemini: Bool, hasClaude: Bool,
                           hasDeepSeek: Bool, hasQwen: Bool,
                           inChina: Bool) -> LLMResolution {
        let domestic: [LLMResolution?] = [hasQwen ? .qwen : nil, hasDeepSeek ? .deepseek : nil]
        let global: [LLMResolution?] = [hasGemini ? .gemini : nil, hasClaude ? .claude : nil]
        let order = (inChina ? domestic + global : global + domestic).compactMap { $0 }
        return order.first ?? .none
    }

    /// 国内网络下解析出的 LLM 是否为被墙端点（Gemini/Claude 直连必然超时）。
    /// 面试前自检与 Onboarding 就绪判定据此显性警告，避免用户带着只能超时的
    /// 配置进入真实面试（纯函数，便于测试）。
    static func llmBlockedInChina(_ resolution: LLMResolution, inChina: Bool) -> Bool {
        inChina && (resolution == .gemini || resolution == .claude)
    }

    /// Resolve an API key by name: Keychain → environment variable.
    static func apiKey(_ name: String) -> String? {
        if let v = Secrets.get(name), !v.isEmpty { return v }
        if let v = ProcessInfo.processInfo.environment[name], !v.isEmpty { return v }
        return nil
    }

    /// Drop UserDefaults keys left behind by removed features so upgraded installs
    /// don't keep dead entries. `removeObject` is a no-op when the key is absent,
    /// so this is safe to call on every launch.
    static func cleanupLegacyKeys() {
        UserDefaults.standard.removeObject(forKey: "nm_interview_mode")  // 文系/技术 模式开关（已移除）
    }

    /// 离线判断用户是否很可能在中国大陆（无网络调用）。时区优先——命中"人在国内、
    /// 系统 Region 设成日本"（就活用户常见）；Region==CN 兜底。参数可注入，便于测试。
    static func isLikelyInChina(timeZone: TimeZone = .current, locale: Locale = .current) -> Bool {
        let chinaZones: Set<String> = [
            "Asia/Shanghai", "Asia/Urumqi", "Asia/Chongqing", "Asia/Harbin",
        ]
        if chinaZones.contains(timeZone.identifier) { return true }
        if locale.region?.identifier == "CN" { return true }
        return false
    }
}
