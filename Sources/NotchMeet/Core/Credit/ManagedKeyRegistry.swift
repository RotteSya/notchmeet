import CryptoKit
import Foundation

/// 「这个 Key 是不是我们发的」——按**值**回答，而不是按来源标记。
///
/// 旧实现把受管标记存在 UserDefaults(`nm_key_managed_*`)，而计费完全建立在它之上
/// （`CreditPolicy.isMetered`）。于是有两条零成本的免计量路径：
/// 一是 `defaults write com.notchmeet.app nm_key_managed_… -bool false`；
/// 二是更隐蔽的——设置页的密钥行会**预填真实 Key**，用户一个字不改点「保存」，
/// `markKeyManaged(name, false)` 就把受管降级成自备，从此永久免费用出厂 Key。
///
/// 改为记录受管 Key 值的 SHA256 指纹，与余额同存 Keychain 账本 blob（用户改不动）。
/// 判定按值比对：手输一个恰好等于受管 Key 的值仍然判定为受管。
/// 指纹的持久层。生产实现是 `CreditManager`（写进 Keychain 账本 blob）；
/// 测试注入内存实现，避免碰真钥匙串（重签名的 QA 包读它会弹 ACL 密码框）。
protocol ManagedFingerprintStore: AnyObject {
    func managedFingerprint(for name: String) -> String?
    @discardableResult func setManagedFingerprint(_ fingerprint: String?, for name: String) -> Bool
}

enum ManagedKeyRegistry {
    /// App 会用到的全部 Key 名——迁移与清理都以它为准。
    static let allKeyNames = [
        "DEEPGRAM_API_KEY", "GEMINI_API_KEY", "ANTHROPIC_API_KEY",
        "DEEPSEEK_API_KEY", "DASHSCOPE_API_KEY",
    ]

    /// 持久层出口。默认走额度账本；测试可替换。
    nonisolated(unsafe) static var store: ManagedFingerprintStore = CreditManager.shared

    /// 指纹 = SHA256(value) 的前 16 个 hex 字符。存指纹而非明文：
    /// 账本 blob 万一泄露也不等于泄露 Key。
    static func fingerprint(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return String(digest.map { String(format: "%02x", $0) }.joined().prefix(16))
    }

    /// 登记（managed=true）或撤销（managed=false）一个 Key 的受管身份。
    /// 返回是否成功持久化——写不进去时调用方应告警而不是静默继续。
    @discardableResult
    static func mark(_ name: String, value: String?, managed: Bool) -> Bool {
        guard managed, let value, !value.isEmpty else {
            return store.setManagedFingerprint(nil, for: name)
        }
        return store.setManagedFingerprint(fingerprint(value), for: name)
    }

    /// 当前值是否为受管来源。出厂内置 Key 恒为受管（值可直接比对，无需登记）。
    static func isManaged(name: String, value: String) -> Bool {
        if let builtin = Provisioning.serviceKey(name), builtin == value { return true }
        guard let recorded = store.managedFingerprint(for: name) else { return false }
        return recorded == fingerprint(value)
    }

    /// 一次性迁移：把旧的 UserDefaults 标记转成指纹，然后清掉旧键。
    /// 存量用户升级后受管状态不丢，且旧的可写标记从此彻底失效。
    static func migrateLegacyFlagsIfNeeded(keyNames: [String] = allKeyNames) {
        let migratedFlag = "nm_managed_fp_migrated_v1"
        guard !UserDefaults.standard.bool(forKey: migratedFlag) else { return }
        for name in keyNames {
            let legacyKey = "nm_key_managed_\(name)"
            if UserDefaults.standard.bool(forKey: legacyKey),
               let v = Secrets.get(name), !v.isEmpty {
                mark(name, value: v, managed: true)
                NSLog("[credit] migrated managed flag → fingerprint for %@", name)
            }
            UserDefaults.standard.removeObject(forKey: legacyKey)
        }
        UserDefaults.standard.set(true, forKey: migratedFlag)
    }
}

/// 写入 API Key 的**唯一**入口。
///
/// 「写 Key」带有计费语义（受管即计量），旧代码却把这段逻辑复制在 3 个 UI 视图
/// + 2 个 Core 入口共五份，任一处漏掉或写错受管标记，就是「白嫖受管服务」或
/// 反向的「BYO 用户被误计费」。收敛到这里之后，视图层不再直接碰 Secrets。
enum KeyProvisioner {
    /// 应用一批 Key（充值码 nmc1 / 设置码 nmk1 / 出厂配置）。
    /// `managed=true` 表示这些 Key 由我们发放，使用它们要计量。
    /// 返回是否至少写入了一个非空 Key。
    @discardableResult
    static func apply(_ keys: [String: String], managed: Bool) -> Bool {
        var wrote = false
        for (name, raw) in keys {
            let v = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !v.isEmpty else { continue }
            Secrets.set(name, v)
            ManagedKeyRegistry.mark(name, value: v, managed: managed)
            wrote = true
        }
        return wrote
    }

    /// 单个 Key 的保存/清除（设置页密钥行）。空值 = 删除。
    ///
    /// 注意这里**不无条件撤销**受管登记：用户对预填的同一个值点「保存」时，
    /// 指纹比对仍会判定为受管——这正是旧实现被一键降级的地方。
    static func set(_ name: String, value: String) {
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !v.isEmpty else {
            Secrets.delete(name)
            ManagedKeyRegistry.mark(name, value: nil, managed: false)
            return
        }
        let stillManaged = ManagedKeyRegistry.isManaged(name: name, value: v)
        Secrets.set(name, v)
        if !stillManaged {
            // 值确实变成了用户自己的 Key → 撤销受管登记（BYO 不计量）。
            ManagedKeyRegistry.mark(name, value: nil, managed: false)
        }
    }
}
