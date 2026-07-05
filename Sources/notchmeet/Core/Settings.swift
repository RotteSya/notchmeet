import Foundation

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
