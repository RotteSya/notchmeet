import XCTest
@testable import notchmeet

/// F1: 段首「無ラベル質問」ヒューリスティックの誤爆。旧実装は なぜ/どのよう/何を が
/// 文中に含まれるだけで質問と見なし、実在ユーザーの面接稿（JINS 終面）で
///   - 「研究テーマについて教えてください」の項目を丸ごと破壊（見出しが空回答で捨てられ、
///     回答の第一段落が偽の質問になる）
///   - 「ESの3つのAttitude経験について」の回答を分裂（34字の断片だけ残る）
/// を引き起こした。質問と認めるのは「疑問・依頼で終わる行」だけにする。
final class ScriptParserTighteningTests: XCTestCase {
    /// JINS 稿の実パターン：回答の第一段落に「どのように」が含まれる。
    func testAnswerParagraphWithInterrogativeWordStaysInAnswer() {
        let entries = ScriptParser.parse("""
        ## 研究テーマについて教えてください

        研究では、取締役会の多様性が情報開示とどのように関係するかを見ています。

        企業ごとに開示の形式が違い、単純に判断できない点が難しいところです。
        """)

        XCTAssertEqual(entries.map(\.question), ["研究テーマについて教えてください"])
        XCTAssertTrue(entries[0].answer.contains("どのように関係するか"))
        XCTAssertTrue(entries[0].answer.contains("難しいところです"))
    }

    /// JINS 稿の実パターン：回答の途中段落に「なぜ」が含まれる。
    func testAnswerParagraphWithMidSentenceNazeStaysInAnswer() {
        let entries = ScriptParser.parse("""
        ## ESの経験について

        学生会で表彰式を運営した経験に、三つの姿勢が表れています。

        人手が足りず、他部門に協力をお願いしましたが、まず一人ひとりの不安を聞き、なぜその役割をお願いしたいのかを説明しました。

        結果として、式典を成功させることができました。
        """)

        XCTAssertEqual(entries.map(\.question), ["ESの経験について"])
        XCTAssertTrue(entries[0].answer.contains("なぜその役割"))
        XCTAssertTrue(entries[0].answer.contains("式典を成功"))
    }

    /// 本物の質問行（疑問・依頼で終わる）は引き続き見出しとして認識される。
    func testGenuineParagraphStartQuestionsStillRecognized() {
        let entries = ScriptParser.parse("""
        なぜ当社を志望するのですか。
        回答：御社の理念に共感したからです。

        自己PRをお願いします。
        A: 強みは実行力です。

        你能接受加班吗
        答：可以，我会合理安排时间。
        """)

        XCTAssertEqual(entries.map(\.question),
                       ["なぜ当社を志望するのですか。", "自己PRをお願いします。", "你能接受加班吗"])
    }

    /// ATX/Setext 見出しの Q/深掘り ラベルは剥がして正規の質問文にする。
    func testHeadingLabelsAreStripped() {
        let entries = ScriptParser.parse("""
        #### **深掘り: 一番難しかったことは何ですか**
        バランスの判断です。

        ## Q2: あなたの強みは何ですか
        実行力です。
        """)

        XCTAssertEqual(entries.map(\.question),
                       ["一番難しかったことは何ですか", "あなたの強みは何ですか"])
    }

    /// JINS 稿の実パターン：回答の結びの段落が「〜たいと考えています。本日はどうぞ
    /// よろしくお願いいたします。」のように挨拶で終わる。お願いします 接尾だけ見ると
    /// 依頼形＝質問と誤爆し、自己紹介の結び段落が丸ごと消える。
    func testClosingParagraphEndingWithGreetingStaysInAnswer() {
        let entries = ScriptParser.parse("""
        ## 自己紹介

        王と申します。学生時代は代行サービスづくりに取り組みました。

        JINSでも、納得して選べる店舗体験を作っていきたいと考えています。本日はどうぞよろしくお願いいたします。

        ## 就職活動の軸

        私の軸は三つあります。
        """)

        XCTAssertEqual(entries.map(\.question), ["自己紹介", "就職活動の軸"])
        XCTAssertTrue(entries[0].answer.contains("本日はどうぞよろしくお願いいたします。"),
                      "greeting-final paragraph must stay in the answer")
    }

    /// 回答の結びの礼儀文は（段落頭でも）質問にならない — 既存契約の再確認。
    func testPoliteClosingsNeverBecomeQuestions() {
        let entries = ScriptParser.parse("""
        # 最後に一言
        本日はありがとうございました。

        本日はよろしくお願いいたします。
        """)

        XCTAssertEqual(entries.count, 1)
        XCTAssertTrue(entries[0].answer.contains("本日はよろしくお願いいたします。"))
    }
}
