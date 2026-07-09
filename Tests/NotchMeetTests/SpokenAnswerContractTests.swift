import XCTest
@testable import notchmeet

final class SpokenAnswerContractTests: XCTestCase {
    func testLivePromptRequiresAContinuousSpeakableAnswer() {
        let system = Prompts.system(context: "")
        let user = Prompts.user(question: "自己紹介をお願いします。", history: "")

        XCTAssertTrue(system.contains("そのまま声に出して答えられる"))
        XCTAssertTrue(system.contains("箇条書き、番号、見出し、Markdown"))
        XCTAssertFalse(system.contains("箇条書き 2〜4 点のみ"))
        XCTAssertTrue(user.contains("完成した回答文だけ"))
        XCTAssertFalse(user.contains("要点を箇条書き"))
    }

    func testNotchPresentationPreservesUserScriptVerbatim() {
        let original = "**強み**は分析力です。\n1. 売上を分析しました。\nよろしくお願いいたします。"
        let rendered = NotchPresentation.text(
            answer: original,
            message: .completed,
            errorDetail: nil,
            strings: AppStrings(language: .zh)
        )

        XCTAssertEqual(rendered, original)
    }

    func testSpokenAnswerFormatRoundTrips() throws {
        let entry = BankEntry(id: "strength", intent: "強み", question: "強みは？",
                              answer: "私の強みは分析力です。", locked: false, format: .spoken)
        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(BankEntry.self, from: data)

        XCTAssertEqual(decoded.format, .spoken)
        XCTAssertEqual(decoded.answer, entry.answer)
    }

    func testAIFormatterRemovesBulletAndMarkdownSyntax() {
        let raw = """
        - **結論**：私の強みは分析力です。
        2. 売上データを分析し、改善策を提案しました。
        ・御社でもこの経験を活かしたいと考えています。
        """

        XCTAssertEqual(
            SpokenAnswerFormatter.normalize(raw),
            "結論：私の強みは分析力です。売上データを分析し、改善策を提案しました。御社でもこの経験を活かしたいと考えています。"
        )
    }
}
