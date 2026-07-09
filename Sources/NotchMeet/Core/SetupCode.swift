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
        return obj
    }
}
