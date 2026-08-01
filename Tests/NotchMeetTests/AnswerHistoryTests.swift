import XCTest
@testable import notchmeet

/// 「被追问打断 → 上一条回答永久丢失」的修复（审计 #26）。回看必须满足三条不变量：
///   1. 看得到被替换掉的那一条；
///   2. 回看态在 model 上有**显式**标记（旧答案绝不能被读成当前该说的话）；
///   3. 新问题一来立刻回到当下，且不能把新回合的字段还原成旧的。
@MainActor
final class AnswerHistoryTests: XCTestCase {

    private func fixture() -> (AnswerModel, AnswerHistory) {
        let model = AnswerModel()
        return (model, AnswerHistory(model: model))
    }

    /// 核心场景：A1 还没读完，追问 Q2 把 A2 顶上来 —— 回看要拿回 A1，不是 A2。
    func testStepBackSkipsTheAnswerCurrentlyOnScreen() {
        let (model, history) = fixture()
        history.record(epoch: 1, question: "学生時代に力を入れたことは？", answer: "A1", intent: "ガクチカ")
        history.record(epoch: 2, question: "それを弊社でどう生かせますか？", answer: "A2", intent: "貢献")
        model.answer = "A2"   // 屏幕上是 A2

        history.stepBack()

        XCTAssertEqual(model.answer, "A1", "回看要给出被顶替掉的上一条，而不是屏幕上已有的那条")
        XCTAssertEqual(model.question, "学生時代に力を入れたことは？", "问题行必须一起回到那一轮")
        XCTAssertEqual(model.review, AnswerModel.ReviewBadge(position: 1, count: 2))
    }

    /// 回看态必须在 model 上显式可见——刘海据此换琥珀色标识。
    func testReviewBadgeIsSetAndClearedHonestly() {
        let (model, history) = fixture()
        history.record(epoch: 1, question: "Q1", answer: "A1", intent: "")
        history.record(epoch: 2, question: "Q2", answer: "A2", intent: "")
        model.answer = "A2"

        XCTAssertNil(model.review, "实时态不得带回看标识")
        history.stepBack()
        XCTAssertNotNil(model.review)
        XCTAssertTrue(history.isReviewing)
        history.returnToLive()
        XCTAssertNil(model.review, "回到当前必须撤掉标识")
        XCTAssertFalse(history.isReviewing)
    }

    /// 回到当前 = 还原进入回看那一刻的整屏（回看不能吃掉正在生成的答案）。
    func testReturnToLiveRestoresTheSnapshot() {
        let (model, history) = fixture()
        history.record(epoch: 1, question: "Q1", answer: "A1", intent: "自己紹介")
        model.answer = "生成中の途中まで"
        model.question = "Q2"
        model.intentLabel = "志望動機"
        model.status = .streaming
        model.message = .suggesting

        history.stepBack()
        XCTAssertEqual(model.answer, "A1")

        history.returnToLive()
        XCTAssertEqual(model.answer, "生成中の途中まで")
        XCTAssertEqual(model.question, "Q2")
        XCTAssertEqual(model.intentLabel, "志望動機")
        XCTAssertEqual(model.status, .streaming)
        XCTAssertEqual(model.message, .suggesting)
    }

    /// 新一轮问答开始：离开回看但**不还原**——TurnManager 紧接着要写自己的问题/状态，
    /// 还原会把新回合的字段盖回旧值（面试里最坏的一种错位）。
    func testAbandonReviewDoesNotRestoreStaleFields() {
        let (model, history) = fixture()
        history.record(epoch: 1, question: "Q1", answer: "A1", intent: "")
        model.answer = "A_live"
        history.stepBack()
        XCTAssertEqual(model.answer, "A1")

        history.abandonReview()

        XCTAssertNil(model.review)
        XCTAssertFalse(history.isReviewing)
        XCTAssertEqual(model.answer, "A1", "abandon 只撤标识，不得把字段还原（新回合马上会覆写）")
    }

    /// 单键循环：退到最早一条后再按，回到当前而不是卡住。
    func testStepBackAtOldestReturnsToLive() {
        let (model, history) = fixture()
        history.record(epoch: 1, question: "Q1", answer: "A1", intent: "")
        history.record(epoch: 2, question: "Q2", answer: "A2", intent: "")
        model.answer = "A2"

        history.stepBack()                       // → A1（最早一条）
        XCTAssertEqual(model.answer, "A1")
        history.stepBack()                       // 再按 → 回到当前
        XCTAssertFalse(history.isReviewing)
        XCTAssertEqual(model.answer, "A2")
    }

    /// 只有一条、且它就在屏幕上时没有可回看的东西——不进回看态，也不给死按钮。
    func testNothingToReviewWhenOnlyTheOnScreenAnswerExists() {
        let (model, history) = fixture()
        history.record(epoch: 1, question: "Q1", answer: "A1", intent: "")
        model.answer = "A1"

        XCTAssertFalse(history.canStepBack)
        history.stepBack()
        XCTAssertFalse(history.isReviewing)
        XCTAssertNil(model.review)
    }

    /// 迟到的原稿命中会让同一轮再次定稿：按 epoch 就地更新，不堆成两条。
    func testLateScriptSwapUpdatesTheSameTurnInPlace() {
        let (_, history) = fixture()
        history.record(epoch: 7, question: "Q", answer: "live で生成した答え", intent: "")
        history.record(epoch: 7, question: "Q", answer: "準備した原稿の答え", intent: "自己紹介")

        XCTAssertEqual(history.entries.count, 1)
        XCTAssertEqual(history.entries.first?.answer, "準備した原稿の答え")
    }

    /// 面试官重复同一问题（不同 epoch）是两轮，不能被合并掉。
    func testSameQuestionInDifferentTurnsStaysTwoEntries() {
        let (_, history) = fixture()
        history.record(epoch: 1, question: "もう一度お願いします", answer: "A1", intent: "")
        history.record(epoch: 2, question: "もう一度お願いします", answer: "A2", intent: "")
        XCTAssertEqual(history.entries.count, 2)
    }

    /// 新一场面试必须清空：拿上一家公司的回答回答这一家是最致命的失败模式。
    func testResetClearsPreviousSession() {
        let (model, history) = fixture()
        history.record(epoch: 1, question: "Q1", answer: "A1", intent: "")
        history.stepBack()

        history.reset()

        XCTAssertTrue(history.entries.isEmpty)
        XCTAssertFalse(history.isReviewing)
        XCTAssertNil(model.review)
    }

    /// 空答案 / 空问题不入库（失败回合不该占一个回看位）。
    func testEmptyTurnsAreNotRecorded() {
        let (_, history) = fixture()
        history.record(epoch: 1, question: "Q", answer: "   ", intent: "")
        history.record(epoch: 2, question: "", answer: "A", intent: "")
        XCTAssertTrue(history.entries.isEmpty)
    }
}
