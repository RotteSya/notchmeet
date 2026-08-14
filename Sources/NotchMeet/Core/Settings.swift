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

extension Notification.Name {
    /// 外观类设置（如回答字号）变化：刘海据此重排/重绘。
    static let nmAppearanceChanged = Notification.Name("nm.appearance.changed")
    /// 面试语言变化：设置页据此重建当前分区（摘要文案里写着面试语言）。
    static let nmInterviewLanguageChanged = Notification.Name("nm.interview.language.changed")
}

/// Runtime settings + key resolution. Keys come from Keychain first, then env (dev).
enum Settings {
    /// 语言类偏好的存取后端。生产恒为 `.standard`；测试换成独立 suite——这两个键
    /// 是测试会真实改写的全局状态，并行测试进程共享同一个持久域，不隔离会让
    /// 「zh」泄漏进断言默认日语的兄弟测试套件。
    /// `nonisolated(unsafe)`：生产代码从不改写（恒为 .standard），只有串行执行的
    /// 测试 setUp/tearDown 会换。
    nonisolated(unsafe) static var languageDefaults: UserDefaults = .standard

    /// 面试语言（STT 识别语言 + LLM 生成回答的语言）。与界面语言相互独立——
    /// 界面用中文、面试说日语是主流用法。默认日语（既有安装无此键，行为不变）。
    /// setter 自己广播（与 `answerTextSize` 同一模式）：任何写入者都不可能忘记通知。
    static var interviewLanguage: InterviewLanguage {
        get { InterviewLanguage(rawValue: languageDefaults.string(forKey: "nm_interview_language") ?? "") ?? .japanese }
        set {
            languageDefaults.set(newValue.rawValue, forKey: "nm_interview_language")
            NotificationCenter.default.post(name: .nmInterviewLanguageChanged, object: nil)
        }
    }

    /// 「预生成回答」答案库当前是用哪种语言生成的。语言戳与库内容同步写入
    /// （见 `PreGenerator`）；路由取候选时与本场面试语言比对，不一致就整库跳过——
    /// 日语库的答案在中文面试里被逐字上屏是最糟的串场。默认日语：既有安装的库
    /// 全部是旧日语版本。
    static var answerBankLanguage: InterviewLanguage {
        get { InterviewLanguage(rawValue: languageDefaults.string(forKey: "nm_bank_language") ?? "") ?? .japanese }
        set { languageDefaults.set(newValue.rawValue, forKey: "nm_bank_language") }
    }

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

    /// 是否把每场面试的问答留在本机供复盘（审计 #21）。
    ///
    /// 默认开——「哪几问没命中我准备的内容」是唯一能让人越面越准的信号，关掉这个功能
    /// 就退回「打十场也不会变好」。但它存的是面试转录，是本 app 最敏感的数据：仅本机、
    /// 0600、进「删除本地数据」清单、隐私页明说，并且可以在这里关掉（关掉即不再记录）。
    static var keepSessionHistory: Bool {
        get { UserDefaults.standard.object(forKey: "nm_keep_sessions") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "nm_keep_sessions") }
    }

    /// 是否允许「预生成回答」使用本机安装的 claude / codex CLI。
    ///
    /// 默认开：它走用户自己的账号、不消耗本应用额度，质量通常也更好。但它与
    /// 「当前回答模型」显示的服务**不是同一个收件人**（数据进的是用户自己的
    /// Anthropic / OpenAI 账号），所以设置页会在按钮按下之前写明真实引擎，
    /// 关掉即改用已配置的云端服务（按额度计量）。
    static var useLocalCliForPrep: Bool {
        get { UserDefaults.standard.object(forKey: "nm_prep_local_cli") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "nm_prep_local_cli") }
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

    /// 刘海回答字号（可自定义项）。测量与渲染共用 `NotchType`，改这里两边同步。
    enum AnswerTextSize: String, CaseIterable {
        case compact, standard, large
        var points: CGFloat {
            switch self {
            case .compact: 13.5
            case .standard: 15
            case .large: 17.5
            }
        }
    }

    static var answerTextSize: AnswerTextSize {
        get { AnswerTextSize(rawValue: UserDefaults.standard.string(forKey: "nm_answer_size") ?? "") ?? .standard }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "nm_answer_size")
            NotificationCenter.default.post(name: .nmAppearanceChanged, object: nil)
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

    /// Resolve an API key by name: Keychain → environment variable → 出厂内置（受管服务）。
    /// 用户手输/env 的 Key 永远优先于内置 Key——高级用户自带服务时用他们自己的。
    static func apiKey(_ name: String) -> String? {
        if let v = Secrets.get(name), !v.isEmpty { return v }
        if let v = ProcessInfo.processInfo.environment[name], !v.isEmpty { return v }
        if let v = Provisioning.serviceKey(name) { return v }
        return nil
    }

    /// 当前生效的 `name` Key 是否为「受管」来源（出厂内置 / 激活码带入）——受管即计量
    /// （见 `CreditPolicy`）。判定跟随 `apiKey` 的解析顺序，两者永不脱节：
    /// - Keychain 命中 → 按**值指纹**比对（见 `ManagedKeyRegistry`，存 Keychain 账本，
    ///   用户改不动；旧的 UserDefaults 标记一改就能免计量）。
    /// - env 命中 → 开发/BYO，一律不计量。
    /// - 内置命中 → 受管。
    static func keyIsManaged(_ name: String) -> Bool {
        if let v = Secrets.get(name), !v.isEmpty {
            return ManagedKeyRegistry.isManaged(name: name, value: v)
        }
        if let v = ProcessInfo.processInfo.environment[name], !v.isEmpty { return false }
        return Provisioning.serviceKey(name) != nil
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
