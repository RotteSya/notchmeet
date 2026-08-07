import XCTest
@testable import notchmeet

/// 审计 R1 的回归锁：慢终稿探测的触发/不触发边界。
final class SttHealthTrackerTests: XCTestCase {

    /// 连续两轮超阈值 → 触发（晚高峰 6-14s 的系统性拥塞形态）。
    func testTriggersOnConsecutiveSlowTurns() {
        var t = SttHealthTracker(thresholdMs: 3000, consecutiveNeeded: 2)
        XCTAssertFalse(t.note(deliveryMs: 6000), "第一轮慢还不足以断定拥塞")
        XCTAssertTrue(t.note(deliveryMs: 8000), "连续第二轮慢必须触发")
    }

    /// 单轮尖峰被一轮正常交付打断 → 不触发（一次重连补发不该换引擎）。
    func testSingleSpikeDoesNotTrigger() {
        var t = SttHealthTracker(thresholdMs: 3000, consecutiveNeeded: 2)
        XCTAssertFalse(t.note(deliveryMs: 9000))
        XCTAssertFalse(t.note(deliveryMs: 800), "正常交付必须清零计数")
        XCTAssertFalse(t.note(deliveryMs: 9000))
        XCTAssertTrue(t.note(deliveryMs: 9000))
    }

    /// 阈值是「超过」不是「达到」：贴线交付不计为慢。
    func testExactThresholdIsNotSlow() {
        var t = SttHealthTracker(thresholdMs: 3000, consecutiveNeeded: 1)
        XCTAssertFalse(t.note(deliveryMs: 3000))
        XCTAssertTrue(t.note(deliveryMs: 3001))
    }

    /// reset 清零（新会话 / 已切换引擎）。
    func testResetClearsStreak() {
        var t = SttHealthTracker(thresholdMs: 3000, consecutiveNeeded: 2)
        _ = t.note(deliveryMs: 9000)
        t.reset()
        XCTAssertFalse(t.note(deliveryMs: 9000), "reset 后需要重新累积")
    }

    /// 新增的两条状态文案在两种界面语言下都必须非空且互不相同（防漏翻）。
    func testSwitchedLocalStringsExist() {
        for lang in UILanguage.allCases {
            let s = AppStrings(language: lang)
            XCTAssertFalse(s.runtimeMessage(.sttSwitchedLocal).isEmpty)
            XCTAssertFalse(s.notchStatus(.sttSwitchedLocal).isEmpty)
        }
        XCTAssertNotEqual(AppStrings(language: .zh).runtimeMessage(.sttSwitchedLocal),
                          AppStrings(language: .ja).runtimeMessage(.sttSwitchedLocal))
    }
}
