import XCTest
@testable import notchmeet

/// 第二份真实稿（KEL 一次面接・整合稿格式）暴露的结构缺口。合成等价样本锁定：
/// 文档标题+元数据、HTML 注释、编号 H2、空父标题+变体子标题、▼キーワード 备忘行、
/// 逆質問内的编号问句列表。
final class ScriptParserStructureTests: XCTestCase {
    /// 整合稿开头：H1 标题 + 元数据行 + HTML 注释块 —— 都不是 Q&A，不能成为条目。
    func testDocumentTitleMetadataAndHtmlCommentsAreDropped() {
        let entries = ScriptParser.parse("""
        # 株式会社サンプル 面接 質問と回答

        作成日: 2026-07-10
        応募職種: 総合職 / 営業職
        第一志望: 志望度高

        <!--
        契約: 純Q&Aのみ。出典・戦略メモは基本ファイルへ。
        -->

        ## 1. 志望動機

        御社を志望する理由は二つあります。
        """)

        XCTAssertEqual(entries.map(\.question), ["志望動機"])
        XCTAssertFalse(entries[0].answer.contains("契約"), "HTML comment leaked into an answer")
    }

    /// `## 2. 志望動機` の番号は構造であって質問文ではない。
    func testNumberedAtxHeadingsLoseTheirNumbers() {
        let entries = ScriptParser.parse("""
        ## 2. 志望動機
        理由は二つあります。

        ## 17. 2023年1月から2025年4月までは何をしていましたか
        大学院の準備をしていました。
        """)

        XCTAssertEqual(entries.map(\.question),
                       ["志望動機", "2023年1月から2025年4月までは何をしていましたか"])
    }

    /// 「## 1. 自己紹介」＋「### 30秒版」「### 1分版」：親は空のまま変体サブ見出しが
    /// 続く形式。親トピックを合成しないと 自己紹介 が検索不能になる。
    func testEmptyParentHeadingComposesWithVariantSubheadings() {
        let entries = ScriptParser.parse("""
        ## 1. 自己紹介

        ### 30秒版（指定なしの時はこちら）

        シャと申します。よろしくお願いいたします。

        ### 1分版（「1分で」と言われた時）

        シャと申します。上海で二年働きました。よろしくお願いいたします。

        ## 2. 志望動機

        理由は二つあります。
        """)

        XCTAssertEqual(entries.map(\.question),
                       ["自己紹介・30秒版（指定なしの時はこちら）",
                        "自己紹介・1分版（「1分で」と言われた時）",
                        "志望動機"])
    }

    /// ▼キーワード 行はプロンプター用の備忘 —— 読み上げ原稿に混ぜてはいけない。
    func testKeywordMemoLinesAreStrippedFromAnswers() {
        let entries = ScriptParser.parse("""
        ## 志望動機

        御社を志望する理由は二つあります。

        ▼キーワード: 中立の立場 / 営業が強い / 中国市場

        **深掘り: なぜ御社ですか**

        営業の力が強い点です。

        ▼キーワード: 営業力
        """)

        XCTAssertEqual(entries.map(\.question), ["志望動機", "なぜ御社ですか"])
        XCTAssertFalse(entries[0].answer.contains("▼"), "keyword memo leaked: \(entries[0].answer)")
        XCTAssertFalse(entries[1].answer.contains("▼"))
    }

    /// 逆質問の回答は番号付き質問リストそのもの —— 番号見出しパスも分裂させてはいけない
    /// （前回の修正は無ラベル段落パスだけを免疫にしていて、ここが抜けていた）。
    func testNumberedReverseQuestionListStaysInAnswer() {
        let entries = ScriptParser.parse("""
        ## 29. 逆質問（5問・上から優先）

        1. 若手がこの成長領域に関われるのは、いつ頃からでしょうか。
        2. 順調に立ち上がっていると言われるのは、どんな状態の時でしょうか。
        3. 他社との差が一番出るのは、どのような場面でしょうか。

        ## 30. 最後に一言

        本日はありがとうございました。
        """)

        XCTAssertEqual(entries.map(\.question), ["逆質問（5問・上から優先）", "最後に一言"])
        XCTAssertTrue(entries[0].answer.contains("いつ頃からでしょうか"))
        XCTAssertTrue(entries[0].answer.contains("どのような場面でしょうか"))
    }
}
