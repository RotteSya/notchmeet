import XCTest
@testable import notchmeet

final class ScriptParserTests: XCTestCase {
    func testOriginalMarkdownConventionRemainsVerbatim() {
        let entries = ScriptParser.parse("""
        # 自己紹介
        A: 一行目です。
        二行目です。

        ## 志望動機
        貴社を志望します。
        """)

        XCTAssertEqual(entries.map(\.question), ["自己紹介", "志望動機"])
        XCTAssertEqual(entries[0].answer, "一行目です。\n二行目です。")
        XCTAssertTrue(entries.allSatisfy { $0.locked == true })
    }

    func testRecognizesNumberedBracketedAndPlainQuestionFormats() {
        let entries = ScriptParser.parse("""
        1. 自己紹介
        〇〇大学の趙です。

        【志望動機】
        ユーザー第一の姿勢に共感しました。

        学生時代に力を入れたことを教えてください。
        回答：ゼミでデータ分析に取り組みました。

        質問4：あなたの弱みは何ですか？
        A4: 慎重になりすぎる点です。
        """)

        XCTAssertEqual(entries.map(\.question), [
            "自己紹介", "志望動機", "学生時代に力を入れたことを教えてください。", "あなたの弱みは何ですか？"
        ])
        XCTAssertEqual(entries[2].answer, "ゼミでデータ分析に取り組みました。")
        XCTAssertEqual(entries[3].answer, "慎重になりすぎる点です。")
    }

    func testRecognizesMarkdownTable() {
        let entries = ScriptParser.parse("""
        | 質問 | 回答 |
        | --- | --- |
        | 自己PR | 分析力が強みです。 |
        | 志望理由 | 事業に共感したためです。 |
        """)

        XCTAssertEqual(entries.map(\.question), ["自己PR", "志望理由"])
        XCTAssertEqual(entries.map(\.answer), ["分析力が強みです。", "事業に共感したためです。"])
    }

    func testRecognizesSetextAndBoldHeadings() {
        let entries = ScriptParser.parse("""
        自己紹介
        --------
        趙と申します。

        **逆質問**
        入社後に期待される成果を伺いたいです。
        """)

        XCTAssertEqual(entries.map(\.question), ["自己紹介", "逆質問"])
    }

    func testDoesNotSplitNumberedAnswerBulletsOrPoliteClosing() {
        let entries = ScriptParser.parse("""
        # 強み
        1. 売上データを分析しました。
        2. 改善策を提案しました。

        よろしくお願いいたします。
        """)

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].question, "強み")
        XCTAssertTrue(entries[0].answer.contains("1. 売上データ"))
        XCTAssertTrue(entries[0].answer.contains("よろしくお願いいたします。"))
    }

    func testSupportsChineseAndEnglishLabels() {
        let entries = ScriptParser.parse("""
        问题1：请做一下自我介绍
        答案：我是计算机专业的学生。

        Question 2: Why do you want this role?
        Answer: I enjoy building products.
        """)

        XCTAssertEqual(entries.map(\.question), ["请做一下自我介绍", "Why do you want this role?"])
        XCTAssertEqual(entries.map(\.answer), ["我是计算机专业的学生。", "I enjoy building products."])
    }
}
