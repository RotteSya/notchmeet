import Foundation
import Security

/// API keys live in the macOS Keychain, never in UserDefaults/plaintext (PLAN §10).
enum Secrets {
    private static let service = "com.notchmeet.keys"

    static func set(_ key: String, _ value: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        let status = SecItemAdd(add as CFDictionary, nil)
        if status != errSecSuccess {
            NSLog("[secrets] keychain save FAILED for %@ (OSStatus %d)", key, status)
        }
    }

    static func get(_ key: String) -> String? {
        #if DEBUG
        // 视觉 QA：重新打包的二进制读 Keychain 会触发 ACL 密码弹框（签名不同）。
        // FI_NO_KEYCHAIN=1 直接视为无 Key，QA 流程靠 FI_PROVISIONING 注入服务。
        if ProcessInfo.processInfo.environment["FI_NO_KEYCHAIN"] == "1" { return nil }
        #endif
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func delete(_ key: String) {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        let status = SecItemDelete(q as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            NSLog("[secrets] keychain delete FAILED for %@ (OSStatus %d)", key, status)
        }
    }
}
