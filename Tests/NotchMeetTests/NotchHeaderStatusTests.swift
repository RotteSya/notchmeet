import XCTest
@testable import notchmeet

/// 审计 R3 的回归锁：流已提交后断开时，「这段回答可能不完整」必须真的渲染出来。
///
/// 旧缺陷链：TurnManager.failTurn（已提交分支）写 errorDetail 并把回合收尾成
/// .completed，但正文契约是「answer 非空即原样返回」、状态行只看 message——
/// 于是半截答案顶着「可直接作答」，警告一个像素都没上过屏。
final class NotchHeaderStatusTests: XCTestCase {
    private let s = AppStrings(language: .zh)

    /// 核心案例：answer 非空 + errorDetail → 状态行显示警告本身，且是警告色。
    func testIncompleteWarningShownWhenAnswerPresent() {
        let warning = s.answerMayBeIncomplete
        let h = NotchPresentation.headerStatus(answer: "はい。私の強みは…", message: .completed,
                                               errorDetail: warning, review: nil, strings: s)
        XCTAssertEqual(h.text, warning, "警告文案必须顶掉「可直接作答」")
        XCTAssertTrue(h.warning, "必须以警告色渲染，普通白字与常规状态无法区分")
    }

    /// answer 为空时错误走正文（NotchPresentation.text），状态行保持常规文案，不重复。
    func testEmptyAnswerKeepsRegularStatus() {
        let h = NotchPresentation.headerStatus(answer: "", message: .generationError,
                                               errorDetail: "http 500", review: nil, strings: s)
        XCTAssertEqual(h.text, s.notchStatus(.generationError))
        XCTAssertFalse(h.warning == false && h.text.isEmpty)
    }

    /// 回看角标最优先：「这是旧答案」比「可能不完整」更致命，不能被警告顶掉。
    func testReviewBadgeOutranksIncompleteWarning() {
        let h = NotchPresentation.headerStatus(answer: "旧答案", message: .completed,
                                               errorDetail: s.answerMayBeIncomplete,
                                               review: .init(position: 2, count: 4), strings: s)
        XCTAssertEqual(h.text, s.notchReviewing(position: 2, count: 4))
        XCTAssertTrue(h.warning)
    }

    /// 无异常时维持原状：常规状态文案、常规颜色。
    func testNormalStatusUnchanged() {
        let h = NotchPresentation.headerStatus(answer: "回答本文", message: .suggesting,
                                               errorDetail: nil, review: nil, strings: s)
        XCTAssertEqual(h.text, s.notchStatus(.suggesting))
        XCTAssertFalse(h.warning)
    }
}
