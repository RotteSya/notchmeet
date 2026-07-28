import AppKit
import Foundation

/// Decodes a one-paste **setup code** that carries one or more API keys, so a trial user can paste a
/// single string instead of obtaining and entering keys by hand.
///
/// Format: `nmk1.<base64url(JSON)>` where JSON is a flat `{ "<Keychain key name>": "<value>" }` map,
/// e.g. `{"DEEPGRAM_API_KEY":"…","GEMINI_API_KEY":"…"}`. Mint with `scripts/mint-code.sh`.
///
/// This is **purely local — the code *is* the keys**, there is no server. It is obfuscation, not
/// security: anyone can base64-decode it. Only ever hand out **scoped, time-limited (Deepgram TTL),
/// spend-capped** keys, one per recipient, so a leaked or abused code is cheap to revoke.
enum SetupCode {
    static let prefix = "nmk1."

    /// Returns the decoded `[keyName: value]` map, or `nil` if `raw` isn't a setup code.
    ///
    /// 只接受已知的 Key 名（`ManagedKeyRegistry.allKeyNames`）：设置码没有签名，
    /// 任何人都能造一张；不做白名单的话，一张精心构造的码可以往钥匙串里塞任意条目。
    static func decode(_ raw: String) -> [String: String]? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.hasPrefix(prefix) else { return nil }
        var b64 = String(s.dropFirst(prefix.count))
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              !obj.isEmpty else { return nil }
        let allowed = Set(ManagedKeyRegistry.allKeyNames)
        let filtered = obj.filter { allowed.contains($0.key) }
        return filtered.isEmpty ? nil : filtered
    }

    /// 应用设置码前的确认。
    ///
    /// 设置码**没有签名**——`nmc1` 充值码有 Ed25519 验签，而 `nmk1` 是纯 base64，
    /// 任何人都能造。兑换框对两者是同一个入口且自动回落，于是存在这样一条攻击：
    /// 攻击者在社群发一张「免费试用码」，内含**他自己的** Deepgram/LLM 密钥；受害者
    /// 粘贴后，整场面试的音频与稿件上下文都发往攻击者名下的服务账号，而 App 只回一句
    /// 「已激活」。用户至少要知道这张码会改写哪些服务、以及数据将发往谁的账号。
    ///
    /// 返回 true 表示用户确认应用。
    @MainActor
    static func confirmApply(_ keys: [String: String], window: NSWindow? = nil) -> Bool {
        let t = AppStrings.current
        let names = keys.keys.sorted().joined(separator: "\n· ")
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = t.setupCodeConfirmTitle
        alert.informativeText = t.setupCodeConfirmBody("· " + names)
        alert.addButton(withTitle: t.setupCodeConfirmApply)
        alert.addButton(withTitle: t.cancel)
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }
}
