import XCTest
@testable import notchmeet

/// 额度用完的提示长在刘海里，不再弹 NSAlert：模态会抢走面试 App 的焦点并阻塞 run loop。
/// （采集暴露本身已由 ScreenShareGuard.runModalGuarded 单独堵上，不是这里的理由。）
final class NotchPromptTests: XCTestCase {
    func testCreditPromptOffersTopUpEnterCodeAndDismiss() {
        XCTAssertEqual(NotchPrompt.credit.actions, [.topUp, .enterCode, .dismiss])
        XCTAssertEqual(NotchPrompt.credit.primaryAction, .topUp)
    }

    func testPromptActionTitlesLocalized() {
        let zh = AppStrings(language: .zh)
        let ja = AppStrings(language: .ja)
        XCTAssertEqual(zh.notchPromptAction(.topUp), "去充值")
        XCTAssertEqual(ja.notchPromptAction(.topUp), "チャージする")
        XCTAssertEqual(zh.notchPromptAction(.dismiss), "稍后")
        XCTAssertEqual(ja.notchPromptAction(.dismiss), "後で")
        // 每个按钮在两种界面语言下都必须有文案——空按钮点不出去。
        for action in NotchPrompt.credit.actions {
            XCTAssertFalse(zh.notchPromptAction(action).isEmpty)
            XCTAssertFalse(ja.notchPromptAction(action).isEmpty)
        }
    }

    /// 「不消耗额度也能用」这条出路原本写在弹窗正文里，撤掉弹窗后挂在按钮的提示上，
    /// 不能一起丢掉。
    func testEnterCodeKeepsTheBringYourOwnKeyHint() {
        XCTAssertNil(AppStrings(language: .zh).notchPromptActionHint(.topUp))
        XCTAssertNotNil(AppStrings(language: .ja).notchPromptActionHint(.enterCode))
        XCTAssertTrue(AppStrings(language: .zh).notchPromptActionHint(.enterCode)?
            .contains("不消耗额度") ?? false)
    }

    // MARK: 排版：操作行永远在卡片内

    /// 回归：答案区的封顶逻辑（#28 长答案改区内滚动）原本只扣底部留白，不知道提示行的存在。
    /// 于是「控制器按有提示把卡片开高、视图却按没提示把答案铺满」，操作行被整条挤出卡片底部——
    /// 额度用完时那三个按钮是用户唯一的出路，裁掉就等于死路。
    /// 卡片必须小到让「剩余高度」而不是 `maxAnswerHeight` 成为起作用的约束——
    /// 正是这个区间当年会出事；卡片够大时答案先撞封顶，反而看不出问题。
    private let card: CGFloat = 500
    private let bodyTop: CGFloat = 120

    func testPromptRowStaysInsideTheCardEvenWithAHugeAnswer() {
        let answerH = NotchMetrics.answerHeight(measured: 10_000, cardHeight: card,
                                                bodyTop: bodyTop, prompt: .credit)
        XCTAssertLessThan(answerH, NotchMetrics.maxAnswerHeight,
                          "本例必须落在「剩余高度封顶」的分支，否则测不到回归的那条路径")
        let promptBottom = bodyTop + answerH + NotchMetrics.promptReserve(.credit)
        XCTAssertLessThanOrEqual(promptBottom, card,
                                 "操作行的底边越出了卡片——按钮会被裁掉")
    }

    /// 没有提示时不该凭空少一截：同样的卡片，答案区必须正好多出预留的那一截。
    func testNoPromptGivesTheAnswerAllTheRoomBack() {
        let withPrompt = NotchMetrics.answerHeight(measured: 10_000, cardHeight: card,
                                                   bodyTop: bodyTop, prompt: .credit)
        let without = NotchMetrics.answerHeight(measured: 10_000, cardHeight: card,
                                                bodyTop: bodyTop, prompt: nil)
        XCTAssertEqual(without - withPrompt, NotchMetrics.promptReserve(.credit), accuracy: 0.01)
        XCTAssertEqual(NotchMetrics.promptReserve(nil), 0)
    }
}
