import XCTest
@testable import notchmeet

final class QuestionMatcherTests: XCTestCase {
    private func entry(_ question: String) -> BankEntry {
        BankEntry(id: question, intent: question, question: question, answer: question, locked: true)
    }

    func testCanonicalTopicOutranksUnrelatedLongQuestions() {
        let entries = [
            entry("学生時代にチームで努力した経験を教えてください"),
            entry("最近関心を持った課題について教えてください"),
            entry("自己紹介"),
            entry("志望動機"),
            entry("キャリアプラン"),
        ]

        let result = QuestionMatcher.ranked(entries, for: "当社への志望動機を教えてください。", limit: 2)
        XCTAssertEqual(result.first?.question, "志望動機")
    }

    func testAliasRecognitionRanksGakuchikaFirst() {
        let entries = [entry("自己PR"), entry("逆質問"), entry("ガクチカ"), entry("弱み")]
        let result = QuestionMatcher.ranked(entries,
                                            for: "学生時代に最も力を入れたことをお聞かせください。",
                                            limit: 1)
        XCTAssertEqual(result.first?.question, "ガクチカ")
    }

    func testStrengthAndWeaknessBothRemainTopCandidates() {
        let entries = [entry("志望動機"), entry("強み"), entry("研究内容"), entry("弱み"), entry("逆質問")]
        let result = QuestionMatcher.ranked(entries, for: "あなたの強みと弱みを教えてください。", limit: 2)
        XCTAssertEqual(Set(result.map(\.question)), Set(["強み", "弱み"]))
    }

    func testTieKeepsUserAuthoredOrder() {
        let entries = [entry("趣味"), entry("特技"), entry("アルバイト")]
        let result = QuestionMatcher.ranked(entries, for: "休日", limit: 2)
        XCTAssertEqual(result.map(\.question), ["趣味", "特技"])
    }
}
