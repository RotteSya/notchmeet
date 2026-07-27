import XCTest
@testable import notchmeet

/// 计量所有权与账实一致性的回归锁。
///
/// 这些用例对应线上已存在的三个缺陷：
/// 1. 计量计时器的停止责任在 UI 层，通知被吞就会持续扣费到清零；
/// 2. 透支无上限结转，静默吃掉用户的下一次充值；
/// 3. 账本写失败仍宣告兑换成功，用户重启后余额消失、码却已作废。
final class CreditOwnershipTests: XCTestCase {

    private func makeLedger(granted: Int,
                            store: CreditEngineTests.MemoryStore = .init()) -> CreditLedger {
        let ledger = CreditLedger(store: store)
        if granted > 0 { ledger.grantWelcome(seconds: granted) }
        return ledger
    }

    // MARK: - 计量所有权

    /// 余额归零时计量必须自己停——即使上层完全忽略 onAlert。
    /// 旧实现里 AppController 用 `guard recording else { return }` 吞掉通知，
    /// 计时器就成了无人能停的孤儿。
    func testMeteringStopsItselfWhenExhaustedEvenIfAlertIsIgnored() {
        let mgr = CreditManager(ledger: makeLedger(granted: 3))
        mgr.onAlert = { _ in }          // 上层「吞掉」通知，重现旧 bug 的条件
        mgr.beginSession(metered: true)
        for _ in 0..<10 { mgr.tick() }
        XCTAssertFalse(mgr.meteringActive, "耗尽后计量必须已由 CreditManager 自行停止")
        XCTAssertEqual(mgr.balanceSeconds, 0)
    }

    /// 耗尽只应通知一次，且通知发出时表已经停了。
    func testExhaustedAlertFiresOnceAndAfterMeteringStopped() {
        let mgr = CreditManager(ledger: makeLedger(granted: 2))
        var exhaustedCount = 0
        var meteringWhenAlerted: Bool?
        mgr.onAlert = { alert in
            if alert == .exhausted {
                exhaustedCount += 1
                meteringWhenAlerted = mgr.meteringActive
            }
        }
        mgr.beginSession(metered: true)
        for _ in 0..<8 { mgr.tick() }
        XCTAssertEqual(exhaustedCount, 1, "耗尽只应通知一次")
        XCTAssertEqual(meteringWhenAlerted, false, "通知发出时计量应已停止")
    }

    // MARK: - 账实一致

    /// 透支不得结转：usedSeconds 永远不超过 grantedSeconds，
    /// 否则用户充 60 分钟后看到的余额会莫名少一截。
    func testOverdraftIsClampedSoNextTopUpIsWhole() {
        let ledger = makeLedger(granted: 2)
        for _ in 0..<50 { ledger.consume(seconds: 1) }
        XCTAssertEqual(ledger.state.usedSeconds, 2, "已用不得超过已获得")
        ledger.redeem(id: "top-up", seconds: 3600)
        XCTAssertEqual(ledger.balanceSeconds, 3600, "充值 60 分钟后余额必须是完整的 60 分钟")
    }

    /// 账本写不进去 → 兑换必须报失败，且这张码没被消耗，可以原样重试。
    func testRedeemFailsLoudlyWhenStorageRejectsAndCodeStaysUsable() {
        let store = CreditEngineTests.MemoryStore()
        store.failWrites = true
        let ledger = CreditLedger(store: store)
        XCTAssertEqual(ledger.redeem(id: "code-1", seconds: 600), .storageFailed)
        XCTAssertEqual(ledger.balanceSeconds, 0, "没落盘就不该有余额")

        store.failWrites = false
        XCTAssertEqual(ledger.redeem(id: "code-1", seconds: 600), .ok, "写失败的码必须仍可重试")
        XCTAssertEqual(ledger.balanceSeconds, 600)
    }

    /// 损坏的账本进入只读降级：不清零、不覆盖，给人工恢复留机会。
    func testCorruptLedgerIsReadOnlyAndNeverOverwritten() {
        let store = CreditEngineTests.MemoryStore()
        store.data = Data("{ this is not a ledger".utf8)
        let ledger = CreditLedger(store: store)
        XCTAssertEqual(ledger.loadState, .corrupt)
        XCTAssertFalse(ledger.isWritable)
        XCTAssertFalse(ledger.grantWelcome(seconds: 3600), "损坏态不得入账")
        XCTAssertEqual(ledger.redeem(id: "x", seconds: 60), .storageFailed)
        XCTAssertEqual(store.saves, 0, "损坏的原始数据绝不能被覆盖")
    }

    // MARK: - 防重放（第二处记录）

    /// 删掉 Keychain 账本不得让已兑换的码重新可用。
    /// 旧实现下 `security delete-generic-password -s com.notchmeet.credit` 就能让
    /// 历史买过的每一张码再兑一次，迎新赠礼也能反复领。
    func testDeletingTheKeychainLedgerDoesNotRevivedSpentCodes() {
        let dir = NSTemporaryDirectory() + "nm-journal-\(UUID().uuidString)"
        RedemptionJournal.overridePath = dir + "/.redemptions.json"
        defer {
            RedemptionJournal.overridePath = nil
            try? FileManager.default.removeItem(atPath: dir)
        }

        XCTAssertFalse(RedemptionJournal.hasRedeemed("code-X"))
        RedemptionJournal.noteRedeemed("code-X")
        XCTAssertTrue(RedemptionJournal.hasRedeemed("code-X"))

        // 模拟「账本被整个删掉」：新建一个空 store 的账本，日志仍在。
        let freshLedger = CreditLedger(store: CreditEngineTests.MemoryStore())
        XCTAssertEqual(freshLedger.state.redeemedCodeIDs, [], "账本确实是空的")
        XCTAssertTrue(RedemptionJournal.hasRedeemed("code-X"),
                      "第二处记录必须幸存——这正是防重放的意义")
    }

    /// 迎新赠礼同理：日志记过就不能再发。
    func testWelcomeGiftIsNotRegrantableAfterLedgerWipe() {
        let dir = NSTemporaryDirectory() + "nm-journal-\(UUID().uuidString)"
        RedemptionJournal.overridePath = dir + "/.redemptions.json"
        defer {
            RedemptionJournal.overridePath = nil
            try? FileManager.default.removeItem(atPath: dir)
        }
        XCTAssertFalse(RedemptionJournal.welcomeGranted)
        RedemptionJournal.noteWelcomeGranted()
        XCTAssertTrue(RedemptionJournal.welcomeGranted)
    }

    // MARK: - Schema 向前兼容（存量用户升级）

    /// 关键回归：Swift 合成的 Codable 解码器**不使用**属性默认值，缺键即抛错。
    /// 若 CreditLedgerState 用合成解码器，新增 schemaVersion/指纹字段会让所有
    /// 存量用户的账本被判为损坏 → 余额清零。这里锁住手写 decodeIfPresent 的行为。
    func testLedgerDecodesLegacyPayloadWithoutNewFields() throws {
        let legacy = """
        {"grantedSeconds":3600,"usedSeconds":120,"redeemedCodeIDs":["a"],"welcomeGranted":true}
        """
        let store = CreditEngineTests.MemoryStore()
        store.data = Data(legacy.utf8)
        let ledger = CreditLedger(store: store)

        XCTAssertEqual(ledger.loadState, .ok, "旧账本必须能正常读入，不能判为损坏")
        XCTAssertEqual(ledger.balanceSeconds, 3480)
        XCTAssertTrue(ledger.state.welcomeGranted, "迎新标记必须保留，否则会重复发赠礼")
        XCTAssertEqual(ledger.state.redeemedCodeIDs, ["a"], "已兑换记录必须保留，否则旧码可重放")
        XCTAssertEqual(ledger.state.schemaVersion, 1)
        XCTAssertTrue(ledger.state.managedKeyFingerprints.isEmpty)
    }

    /// 空 JSON 对象也应安全降级为全默认，而不是抛错。
    func testLedgerDecodesEmptyObject() {
        let store = CreditEngineTests.MemoryStore()
        store.data = Data("{}".utf8)
        let ledger = CreditLedger(store: store)
        XCTAssertEqual(ledger.loadState, .ok)
        XCTAssertEqual(ledger.balanceSeconds, 0)
    }

    /// 往返：新版本写下的账本自己能读回来，字段不丢。
    func testLedgerRoundTripPreservesAllFields() {
        let store = CreditEngineTests.MemoryStore()
        let ledger = CreditLedger(store: store)
        ledger.grantWelcome(seconds: 3600)
        ledger.redeem(id: "code-A", seconds: 600)
        ledger.setManagedFingerprint("deadbeefdeadbeef", for: "DEEPGRAM_API_KEY")
        ledger.consume(seconds: 30)
        ledger.flush()

        let reopened = CreditLedger(store: store)
        XCTAssertEqual(reopened.loadState, .ok)
        XCTAssertEqual(reopened.state.grantedSeconds, 4200)
        XCTAssertEqual(reopened.state.usedSeconds, 30)
        XCTAssertEqual(reopened.state.redeemedCodeIDs, ["code-A"])
        XCTAssertTrue(reopened.state.welcomeGranted)
        XCTAssertEqual(reopened.state.managedKeyFingerprints["DEEPGRAM_API_KEY"], "deadbeefdeadbeef")
    }
}
