import XCTest
@testable import notchmeet

/// F2: 路由输出解析的鲁棒性 + 判据措辞。域内小模型偶尔把 match 编成字符串
/// （{"match":"0"}）；旧实现 `as? Int` 直接判 miss，逐字稿白白丢掉。
final class LLMRouterParseTests: XCTestCase {
    private let cands = [
        BankEntry(id: "c0", intent: "自己紹介", question: "自己紹介", answer: "回答0です。", locked: true),
        BankEntry(id: "c1", intent: "強み", question: "自己PR", answer: "回答1です。", locked: true),
    ]

    func testParsesIntegerMatch() {
        let d = LLMRouter().parse(#"{"intent":"自己紹介","match":1}"#, candidates: cands)
        XCTAssertEqual(d.matchedAnswer, "回答1です。")
    }

    func testParsesStringMatch() {
        let d = LLMRouter().parse(#"{"intent":"自己紹介","match":"0"}"#, candidates: cands)
        XCTAssertEqual(d.matchedAnswer, "回答0です。")
    }

    func testNullAndOutOfRangeAreMisses() {
        XCTAssertNil(LLMRouter().parse(#"{"intent":"x","match":null}"#, candidates: cands).matchedAnswer)
        XCTAssertNil(LLMRouter().parse(#"{"intent":"x","match":7}"#, candidates: cands).matchedAnswer)
        XCTAssertNil(LLMRouter().parse("すみません、判断できません。", candidates: cands).matchedAnswer)
    }

    func testCodeFencedJSONIsTolerated() {
        let d = LLMRouter().parse("```json\n{\"intent\":\"強み\",\"match\":1}\n```", candidates: cands)
        XCTAssertEqual(d.matchedAnswer, "回答1です。")
        XCTAssertEqual(d.intent, "強み")
    }

    /// 可答性判据需要 router 看得到答案本身 —— 候选块必须携带答案开头，
    /// 否则「回答をそのまま読み上げて成立するか」无从判断。
    func testCandidateBlockCarriesAnswerSnippet() {
        let long = BankEntry(id: "L", intent: "ガクチカ", question: "学生時代に力を入れたこと",
                             answer: String(repeating: "あ", count: 300), locked: true)
        let block = LLMRouter.candidateBlock([cands[0], long])
        XCTAssertTrue(block.contains("回答0です。"), "answer snippet missing")
        XCTAssertTrue(block.contains("学生時代に力を入れたこと"))
        XCTAssertLessThan(block.count, 400, "snippets must stay capped for the 3s SLA")
    }

    /// 判据从「同じことを聞いている」（同问性）改为「候補の回答をそのまま読み上げて
    /// 成立するか」（可答性）——面试官的问法永远不会和稿子一字不差。
    func testRouterPromptJudgesAnswerability() {
        let sys = LLMRouter.systemPrompt()
        XCTAssertTrue(sys.contains("回答"), "criterion must be about the prepared ANSWER")
        XCTAssertTrue(sys.contains("そのまま読み上げ"), "criterion must be read-aloud answerability")
        XCTAssertFalse(sys.contains("同じことを聞いている"), "sameness criterion must be gone")
    }
}
