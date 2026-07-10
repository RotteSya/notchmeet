import XCTest
@testable import notchmeet

/// 全面审计补强：从 JINS 终面稿的真实问题分布倒推出来的缺口。
final class EngineAuditTests: XCTestCase {
    /// 终面高频意图（在留资格/转勤/研究内容/留学生相关/入社意思）不在 15 个意图里，
    /// glance 标签会被迫归到不相干类别，PreGenerator 也不会为它们预生成。
    func testIntentListCoversFinalRoundStaples() {
        for intent in ["研究内容", "転勤・勤務地", "外国人・語学", "入社意思確認"] {
            XCTAssertTrue(Intents.list.contains(intent), "missing intent: \(intent)")
        }
    }

    /// live 生成的长度规则（120〜260字）不得压缩用户准备的回答 —— 有原稿时
    /// 文面・长度以原稿为准。
    func testSystemPromptPrefersPreparedAnswerWording() {
        let system = Prompts.system(context: "何か")
        XCTAssertTrue(system.contains("準備した回答"), "system prompt must reference prepared answers")
        XCTAssertTrue(system.contains("要約") || system.contains("改変"),
                      "must forbid summarizing/rewriting the prepared answer")
    }
}

/// 逆質問の回答は「質問文そのもの」— 段首問句ヒューリスティックが二次分裂させる。
final class ScriptParserReverseQuestionTests: XCTestCase {
    func testReverseQuestionEntryKeepsAllPreparedQuestions() {
        let entries = ScriptParser.parse("""
        ## 逆質問

        最初の半年で特に意識すべき行動があれば教えていただきたいです。

        新人のうちから、日々の店舗でどのようなことを見ておくべきでしょうか。

        本日は貴重なお時間をいただき、ありがとうございました。

        ## 最後に一言

        本日はありがとうございました。
        """)

        XCTAssertEqual(entries.map(\.question), ["逆質問", "最後に一言"])
        XCTAssertTrue(entries[0].answer.contains("見ておくべきでしょうか"),
                      "second prepared reverse question must stay in the 逆質問 answer")
        XCTAssertTrue(entries[0].answer.contains("ありがとうございました"))
    }
}
