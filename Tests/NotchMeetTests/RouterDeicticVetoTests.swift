import XCTest
@testable import notchmeet

/// 经历一致性护栏的离线回归（不打网络）。
///
/// 背景：指代型追问「それを弊社で生かすことができますか」被路由 LLM 判给了绑定在
/// **另一段经历**上的桥接稿——prompt 规则两轮迭代都被无视（问句相似度信号太强）。
/// 护栏因此做成确定性代码：这里锁住它的三个组成部分与整体行为。
final class RouterDeicticVetoTests: XCTestCase {

    // MARK: - 指代检测

    func testDeicticMarkersAreRecognized() {
        XCTAssertTrue(LLMRouter.isDeictic("それを弊社で生かすことができますか。"))
        XCTAssertTrue(LLMRouter.isDeictic("その経験から何を学びましたか。"))
        XCTAssertTrue(LLMRouter.isDeictic("先ほどの話について、もう少し詳しく。"))
    }

    /// 「それでは」是话轮开场语（"那么"），不是回指——误判它会让每场面试的
    /// 开场问题都进入否决通道。
    func testDiscourseMarkersAreNotDeictic() {
        XCTAssertFalse(LLMRouter.isDeictic("それでは、自己紹介をお願いします。"))
        XCTAssertFalse(LLMRouter.isDeictic("それじゃあ、次の質問に移ります。"))
        XCTAssertFalse(LLMRouter.isDeictic("転勤は大丈夫ですか。"))
        XCTAssertFalse(LLMRouter.isDeictic("弊社ではどのように貢献できますか。"))
    }

    // MARK: - 内容词提取

    func testContentWordsExtractKanjiKatakanaAndLatin() {
        let words = LLMRouter.contentWords("MBAでデータ分析を体系的に学び直しました。")
        XCTAssertTrue(words.contains("mba"))
        XCTAssertTrue(words.contains("データ"))
        XCTAssertTrue(words.contains("分析"))
        XCTAssertTrue(words.contains("体系的"), "连续汉字按整串提取: \(words)")
    }

    /// 平假名是语法成分：它们的重叠不构成「同一段经历」的证据。
    func testHiraganaIsIgnored() {
        let words = LLMRouter.contentWords("できますかそれをしました")
        XCTAssertTrue(words.isEmpty, "纯平假名不应产生内容词: \(words)")
    }

    // MARK: - 否决行为（实机事故的确定性复现）

    private let mbaHistory = "面接官: なぜMBAに進学されたのですか？\n回答案: 現場で感じた疑問を理論で確かめたくて、進学を決めました。データ分析を体系的に学び直しました。"
    private let wrongBridge = "分かってきたのは、両者のずれです。入れる側は効率を語り、入れられる側は自分が数字で見られていると感じます。御社がシステムをお客様の現場に入れる時も、同じずれが起きると思います。"
    private let matchingBridge = "MBAで学んだデータ分析を、御社の案件で数字の根拠づくりに使えると考えています。現場の疑問を仮説に変える進め方は、要件定義でそのまま活きるはずです。"

    func testWrongExperienceBridgeIsVetoed() {
        let d = RouteDecision(intent: "入社後にやりたいこと", matchedAnswer: wrongBridge)
        let out = LLMRouter.vetoingContextMismatch(
            d, question: "それを弊社で生かすことができますか。", history: mbaHistory)
        XCTAssertNil(out.matchedAnswer, "别的经历的桥接稿必须被否决 → live 生成接手")
        XCTAssertEqual(out.intent, "入社後にやりたいこと", "意图标签保留（刘海仍显示归类）")
    }

    /// 正确绑定的桥接稿（与 history 共享 MBA/データ/分析…）不得被误杀。
    func testMatchingExperienceBridgeSurvives() {
        let d = RouteDecision(intent: "入社後にやりたいこと", matchedAnswer: matchingBridge)
        let out = LLMRouter.vetoingContextMismatch(
            d, question: "それを弊社で生かすことができますか。", history: mbaHistory)
        XCTAssertNotNil(out.matchedAnswer, "同一段经历的准备稿必须放行")
    }

    /// 非指代问题完全不进否决通道——「弊社ではどのように貢献できますか」类
    /// 售卖问题命中通用售卖稿是合法的（内容词可能零重叠）。
    func testNonDeicticQuestionIsNeverVetoed() {
        let d = RouteDecision(intent: "入社後にやりたいこと", matchedAnswer: wrongBridge)
        let out = LLMRouter.vetoingContextMismatch(
            d, question: "弊社ではどのように貢献できますか。", history: mbaHistory)
        XCTAssertNotNil(out.matchedAnswer)
    }

    /// 无 history（对话第一轮）不否决——没有可比对象。
    func testEmptyHistoryIsNeverVetoed() {
        let d = RouteDecision(intent: "自己紹介", matchedAnswer: wrongBridge)
        let out = LLMRouter.vetoingContextMismatch(
            d, question: "それを弊社で生かすことができますか。", history: "")
        XCTAssertNotNil(out.matchedAnswer)
    }

    /// null 决策原样通过。
    func testNullDecisionPassesThrough() {
        let d = RouteDecision(intent: "志望動機", matchedAnswer: nil)
        let out = LLMRouter.vetoingContextMismatch(
            d, question: "それを弊社で生かすことができますか。", history: mbaHistory)
        XCTAssertNil(out.matchedAnswer)
    }
}
