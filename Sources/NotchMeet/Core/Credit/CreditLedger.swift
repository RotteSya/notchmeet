import Foundation
import Security

/// 分钟额度账本（PLAN 商业化：额度制，新用户赠 60 分钟）。
///
/// 记账单位是**秒**：入账（迎新赠礼、充值码）与消耗（受管服务的录音会话）都以秒累计，
/// UI 以分钟展示。账本存 Keychain（独立 service，删除 API Key 不会清账本；重装 App 后
/// 余额仍在），这是「本机诚实用户」级别的防篡改——没有服务器就没有真正的防伪，
/// 充值码的 Ed25519 签名（见 `CreditCode`）保证码本身不可伪造，`redeemedCodeIDs`
/// 保证同一台机器不可重复兑换。
struct CreditLedgerState: Codable, Equatable {
    /// 结构版本。加字段时**必须**同时维护下面的 `init(from:)`——Swift 合成的解码器
    /// 不会使用属性默认值，缺键即 `keyNotFound`，那意味着存量用户的余额被判为损坏。
    var schemaVersion: Int = 1
    var grantedSeconds: Int = 0
    var usedSeconds: Int = 0
    var redeemedCodeIDs: [String] = []
    var welcomeGranted: Bool = false
    /// 受管 Key 的值指纹（key 名 → SHA256 前 16 hex）。计费判定按**值**比对，
    /// 而非用户可写的 UserDefaults 标记。见 `ManagedKeyRegistry`。
    var managedKeyFingerprints: [String: String] = [:]

    var balanceSeconds: Int { max(0, grantedSeconds - usedSeconds) }

    init() {}

    /// 手写解码：所有字段 `decodeIfPresent` + 默认值，保证任何旧版本写下的账本
    /// 都能读进来（向前兼容），新增字段取默认值。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        grantedSeconds = try c.decodeIfPresent(Int.self, forKey: .grantedSeconds) ?? 0
        usedSeconds = try c.decodeIfPresent(Int.self, forKey: .usedSeconds) ?? 0
        redeemedCodeIDs = try c.decodeIfPresent([String].self, forKey: .redeemedCodeIDs) ?? []
        welcomeGranted = try c.decodeIfPresent(Bool.self, forKey: .welcomeGranted) ?? false
        managedKeyFingerprints =
            try c.decodeIfPresent([String: String].self, forKey: .managedKeyFingerprints) ?? [:]
    }
}

/// 账本的持久层抽象：真实实现走 Keychain，测试注入内存实现。
/// `saveLedger` 返回是否真的落盘——写失败绝不能被当成成功。
protocol CreditStore: AnyObject {
    func loadLedger() -> Data?
    @discardableResult func saveLedger(_ data: Data) -> Bool
}

/// Keychain 持久层。service 与 `Secrets`（com.notchmeet.keys）分离：
/// 「删除本地数据／清除密钥」不应该顺带清掉用户花钱买的额度。
final class KeychainCreditStore: CreditStore {
    private let service = "com.notchmeet.credit"
    private let account = "ledger"

    func loadLedger() -> Data? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    @discardableResult
    func saveLedger(_ data: Data) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(base as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = base
            add[kSecValueData as String] = data
            // 账本要在锁屏后的后台 flush 里也能写入。
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            if addStatus != errSecSuccess {
                NSLog("[credit] keychain add FAILED (OSStatus %d)", addStatus)
                return false
            }
            return true
        }
        if status != errSecSuccess {
            NSLog("[credit] keychain update FAILED (OSStatus %d)", status)
            return false
        }
        return true
    }
}

/// 账本：状态 + 持久化。所有变更立即可读（内存态），写盘由调用方节流
/// （`CreditManager` 每 15s / 会话结束 / 入账时 flush）。
final class CreditLedger {
    /// 载入结果。`.corrupt` = 读到了数据但解不开：此时**绝不覆盖**，
    /// 否则用户已购余额会被一次无关的写操作抹掉。
    enum LoadState: Equatable { case ok, fresh, corrupt }

    private(set) var state: CreditLedgerState
    private(set) var loadState: LoadState
    private let store: CreditStore
    private var dirty = false

    init(store: CreditStore = KeychainCreditStore()) {
        self.store = store
        guard let data = store.loadLedger() else {
            self.state = CreditLedgerState()
            self.loadState = .fresh
            return
        }
        if let s = try? JSONDecoder().decode(CreditLedgerState.self, from: data) {
            self.state = s
            self.loadState = .ok
        } else {
            // 解不开的账本：以空态运行（不阻断使用），但禁止写回覆盖，
            // 给人工恢复留出机会。
            self.state = CreditLedgerState()
            self.loadState = .corrupt
            NSLog("[credit] LEDGER CORRUPT (%d bytes) — read-only, refusing to overwrite", data.count)
        }
    }

    var balanceSeconds: Int { state.balanceSeconds }
    /// 损坏态下一切写入都被拒绝，调用方据此提示用户而不是静默丢钱。
    var isWritable: Bool { loadState != .corrupt }

    /// 迎新赠礼：仅一次。返回是否真的入了账。
    @discardableResult
    func grantWelcome(seconds: Int) -> Bool {
        guard isWritable, !state.welcomeGranted else { return false }
        state.welcomeGranted = true
        state.grantedSeconds += seconds
        dirty = true
        return flush()
    }

    /// 充值码入账。同一 id 只能兑换一次（本地防线）。
    enum RedeemOutcome: Equatable { case ok, alreadyRedeemed, storageFailed }
    func redeem(id: String, seconds: Int) -> RedeemOutcome {
        guard isWritable else { return .storageFailed }
        guard !state.redeemedCodeIDs.contains(id) else { return .alreadyRedeemed }
        let snapshot = state
        state.redeemedCodeIDs.append(id)
        state.grantedSeconds += seconds
        dirty = true
        guard flush() else {
            // 没落盘就不算兑换：回滚内存态，让用户可以重试同一张码，
            // 而不是「钱付了、码废了、余额没了」。
            state = snapshot
            dirty = false
            return .storageFailed
        }
        return .ok
    }

    /// 消耗（录音计量的 1s tick）。**钳到已获得总量**——透支结转会静默吃掉
    /// 用户下一次充值（充 60 分钟却显示不足 60），比少扣更伤信任。
    func consume(seconds: Int) {
        guard isWritable, seconds > 0 else { return }
        state.usedSeconds = min(state.usedSeconds + seconds, state.grantedSeconds)
        dirty = true
    }

    /// 受管 Key 的值指纹登记（`ManagedKeyRegistry` 调用）。
    @discardableResult
    func setManagedFingerprint(_ fingerprint: String?, for name: String) -> Bool {
        guard isWritable else { return false }
        if let fingerprint { state.managedKeyFingerprints[name] = fingerprint }
        else { state.managedKeyFingerprints.removeValue(forKey: name) }
        dirty = true
        return flush()
    }

    /// 落盘。写失败**保留 dirty**，下一次 flush 会重试——绝不假装成功。
    @discardableResult
    func flush() -> Bool {
        guard dirty else { return true }
        guard isWritable, let data = try? JSONEncoder().encode(state) else { return false }
        guard store.saveLedger(data) else { return false }
        dirty = false
        return true
    }
}
