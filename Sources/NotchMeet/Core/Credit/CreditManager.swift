import Combine
import Foundation

/// 计量策略：一场会话是否消耗额度。
/// 规则只有一条：**本场将要用到任何「受管」Key（出厂内置或激活码带入）→ 计量**；
/// 全部自备（BYO Keychain/env）或纯本地（Apple 端侧 STT）→ 免费。
/// 这让高级用户自带 Key 白嫖不了受管服务，也永远不为自己的成本付两次钱。
enum CreditPolicy {
    static func isMetered(stt: SttResolution,
                          llm: LLMResolution,
                          managed: (String) -> Bool) -> Bool {
        if stt == .deepgram, managed("DEEPGRAM_API_KEY") { return true }
        switch llm {
        case .gemini: return managed("GEMINI_API_KEY")
        case .claude: return managed("ANTHROPIC_API_KEY")
        case .deepseek: return managed("DEEPSEEK_API_KEY")
        case .qwen: return managed("DASHSCOPE_API_KEY")
        case .none: return false
        }
    }

    /// 生产入口：真实解析结果 + 真实来源标记。
    static func sessionIsMetered() -> Bool {
        isMetered(stt: ProviderRegistry.sttResolution(),
                  llm: ProviderRegistry.llmResolution(),
                  managed: Settings.keyIsManaged)
    }
}

/// 额度运行时：余额发布、迎新赠礼、充值码兑换、录音会话的秒级计量与预警。
/// 主线程使用（与 AppController/UI 同域）；测试直接调 `tick()` 免等真实计时器。
final class CreditManager: ObservableObject {
    /// 视觉 QA 钩子：`FI_CREDIT_EPHEMERAL` 用内存账本替代真实 Keychain（绝不落盘），
    /// 值 `"fresh"` = 空账本（配合 FI_PROVISIONING 演出迎新赠礼），`"granted:used"`（秒）
    /// = 预置余额。仅影响本进程，正常启动完全走 Keychain。
    static let shared: CreditManager = {
        guard let spec = ProcessInfo.processInfo.environment["FI_CREDIT_EPHEMERAL"] else {
            return CreditManager()
        }
        final class Mem: CreditStore {
            var d: Data?
            func loadLedger() -> Data? { d }
            func saveLedger(_ x: Data) { d = x }
        }
        let ledger = CreditLedger(store: Mem())
        let parts = spec.split(separator: ":").compactMap { Int($0) }
        if parts.count == 2 {
            ledger.grantWelcome(seconds: parts[0])
            ledger.consume(seconds: parts[1])
        }
        NSLog("[credit] EPHEMERAL ledger (%@) — QA only", spec)
        return CreditManager(ledger: ledger)
    }()

    /// 剩余秒数（UI 以分钟展示）。
    @Published private(set) var balanceSeconds: Int = 0
    /// 本场会话是否在计量中（刘海/菜单据此显示余额倒计时）。
    @Published private(set) var meteringActive = false

    /// 低额预警 / 耗尽事件（AppController 接：预警→提示，耗尽→停止录音+充值引导）。
    enum Alert: Equatable {
        case low(minutesLeft: Int)   // 剩 10 分钟、3 分钟各提醒一次
        case exhausted               // 余额归零：立即停止会话
    }
    var onAlert: ((Alert) -> Void)?

    /// 本次启动刚发放了迎新赠礼（onboarding 的「见面礼」步骤据此播放到账动效）。
    private(set) var welcomeGrantedThisLaunch = false

    /// 钱包页展示用：累计获得 / 累计已用（秒）。
    var grantedSeconds: Int { ledger.state.grantedSeconds }
    var usedSeconds: Int { ledger.state.usedSeconds }

    private let ledger: CreditLedger
    private var timer: Timer?
    private var warnedLow10 = false
    private var warnedLow3 = false
    private var ticksSinceFlush = 0

    init(ledger: CreditLedger = CreditLedger()) {
        self.ledger = ledger
        self.balanceSeconds = ledger.balanceSeconds
    }

    /// App 启动时调用：出厂带受管服务的构建发放一次性迎新赠礼。
    /// 公开/开发构建（无内置服务）不发——赠 60 分钟却没有能用的服务只会造成困惑。
    func bootstrap() {
        if Provisioning.hasService,
           ledger.grantWelcome(seconds: Provisioning.welcomeGiftSeconds) {
            welcomeGrantedThisLaunch = true
            NSLog("[credit] welcome gift granted: %ds", Provisioning.welcomeGiftSeconds)
        }
        balanceSeconds = ledger.balanceSeconds
    }

    // MARK: - 兑换

    enum RedeemResult: Equatable {
        case success(minutes: Int, carriesKeys: Bool)
        case alreadyRedeemed
        case expired
        case invalid     // 结构坏 / 验签失败 / 本构建无验签公钥
        case notACode    // 不是 nmc1（调用方可再试 nmk1 设置码等）
    }

    /// 兑换充值码：验签→入账→随码 Key 落 Keychain（标记受管）。
    func redeem(_ raw: String, now: Date = Date()) -> RedeemResult {
        switch CreditCode.verify(raw, publicKeyB64: Provisioning.creditPublicKeyB64, now: now) {
        case .failure(.notACode):
            return .notACode
        case .failure(.expired):
            return .expired
        case .failure:
            return .invalid
        case .success(let payload):
            guard ledger.redeem(id: payload.id, seconds: payload.min * 60) == .ok else {
                return .alreadyRedeemed
            }
            var carriesKeys = false
            if let keys = payload.keys {
                for (name, value) in keys {
                    let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !v.isEmpty else { continue }
                    Secrets.set(name, v)
                    Settings.markKeyManaged(name, true)
                    carriesKeys = true
                }
            }
            balanceSeconds = ledger.balanceSeconds
            NSLog("[credit] redeemed %@: +%d min", payload.id, payload.min)
            return .success(minutes: payload.min, carriesKeys: carriesKeys)
        }
    }

    // MARK: - 会话计量

    /// 录音会话开始。`metered=false`（全 BYO/本地）时不起计时器、不扣一秒。
    func beginSession(metered: Bool) {
        endSession()
        warnedLow10 = false
        warnedLow3 = false
        guard metered else { return }
        meteringActive = true
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        t.tolerance = 0.1
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func endSession() {
        timer?.invalidate()
        timer = nil
        if meteringActive { meteringActive = false }
        ledger.flush()
        ticksSinceFlush = 0
    }

    /// 1s 计量步进。写盘每 15s 节流（崩溃最多少记 15s——算用户便宜）。
    func tick() {
        ledger.consume(seconds: 1)
        balanceSeconds = ledger.balanceSeconds
        ticksSinceFlush += 1
        if ticksSinceFlush >= 15 {
            ledger.flush()
            ticksSinceFlush = 0
        }
        if balanceSeconds <= 0 {
            onAlert?(.exhausted)   // AppController 停止录音（其 stop 路径会调 endSession）
        } else if balanceSeconds <= 180, !warnedLow3 {
            warnedLow3 = true
            warnedLow10 = true     // 3 分钟预警覆盖 10 分钟档
            onAlert?(.low(minutesLeft: 3))
        } else if balanceSeconds <= 600, !warnedLow10 {
            warnedLow10 = true
            onAlert?(.low(minutesLeft: 10))
        }
    }

    /// 会话开始前的硬闸：计量会话 + 零余额 → 不允许开始。
    var canStartMeteredSession: Bool { balanceSeconds > 0 }
}
