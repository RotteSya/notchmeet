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
    var grantedSeconds: Int = 0
    var usedSeconds: Int = 0
    var redeemedCodeIDs: [String] = []
    var welcomeGranted: Bool = false

    var balanceSeconds: Int { max(0, grantedSeconds - usedSeconds) }
}

/// 账本的持久层抽象：真实实现走 Keychain，测试注入内存实现。
protocol CreditStore: AnyObject {
    func loadLedger() -> Data?
    func saveLedger(_ data: Data)
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

    func saveLedger(_ data: Data) {
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
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            if addStatus != errSecSuccess {
                NSLog("[credit] keychain add FAILED (OSStatus %d)", addStatus)
            }
        } else if status != errSecSuccess {
            NSLog("[credit] keychain update FAILED (OSStatus %d)", status)
        }
    }
}

/// 账本：状态 + 持久化。所有变更立即可读（内存态），写盘由调用方节流
/// （`CreditManager` 每 15s / 会话结束 / 入账时 flush）。
final class CreditLedger {
    private(set) var state: CreditLedgerState
    private let store: CreditStore
    private var dirty = false

    init(store: CreditStore = KeychainCreditStore()) {
        self.store = store
        if let data = store.loadLedger(),
           let s = try? JSONDecoder().decode(CreditLedgerState.self, from: data) {
            self.state = s
        } else {
            self.state = CreditLedgerState()
        }
    }

    var balanceSeconds: Int { state.balanceSeconds }

    /// 迎新赠礼：仅一次。返回是否真的入了账。
    @discardableResult
    func grantWelcome(seconds: Int) -> Bool {
        guard !state.welcomeGranted else { return false }
        state.welcomeGranted = true
        state.grantedSeconds += seconds
        dirty = true
        flush()
        return true
    }

    /// 充值码入账。同一 id 只能兑换一次（本地防线）。
    enum RedeemOutcome: Equatable { case ok, alreadyRedeemed }
    func redeem(id: String, seconds: Int) -> RedeemOutcome {
        guard !state.redeemedCodeIDs.contains(id) else { return .alreadyRedeemed }
        state.redeemedCodeIDs.append(id)
        state.grantedSeconds += seconds
        dirty = true
        flush()
        return .ok
    }

    /// 消耗（录音计量的 1s tick）。透支被钳到 0 余额之后仍会记账——
    /// 会话由 `CreditManager` 在 0 时主动停止，这里不做策略。
    func consume(seconds: Int) {
        guard seconds > 0 else { return }
        state.usedSeconds += seconds
        dirty = true
    }

    func flush() {
        guard dirty, let data = try? JSONEncoder().encode(state) else { return }
        store.saveLedger(data)
        dirty = false
    }
}
