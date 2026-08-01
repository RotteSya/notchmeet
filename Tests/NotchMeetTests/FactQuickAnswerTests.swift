import XCTest
@testable import notchmeet

/// 数字・条件系の即答（审计 #19）。
///
/// 「希望年収は？」「入社可能時期は？」——面接官が最も即答を期待し、曖昧に答えると
/// 内容以前に「準備していない」と読まれる一群。従来はこれらも開放質問と同じ経路
/// （router LLM ＋ live 生成の競走）を通り、しかも生成側は「数字を創作しない」と
/// 縛られているため、事実が無ければ数字の入らない一般論しか出せなかった。
final class FactQuickAnswerTests: XCTestCase {
    private var dir: String!

    override func setUp() {
        super.setUp()
        dir = NSTemporaryDirectory() + "fq-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        setenv("FI_FACTS", dir + "/facts.json", 1)
    }

    override func tearDown() {
        unsetenv("FI_FACTS")
        try? FileManager.default.removeItem(atPath: dir)
        super.tearDown()
    }

    private func store(_ notesBlock: String) -> FactStore {
        let s = FactStore()
        XCTAssertTrue(s.save(FactsTextFormat.parse("# メモ\n" + notesBlock)))
        return FactStore()
    }

    // MARK: - 命中

    func testSalaryQuestionIsAnsweredFromTheNoteVerbatim() {
        let facts = store("希望年収: 400万円（応相談）")
        let answer = FactQuickAnswer.answer(for: "希望年収はどのくらいをお考えですか。", facts: facts)
        XCTAssertEqual(answer, "400万円（応相談）を希望しております。")
    }

    func testStartDateQuestion() {
        let facts = store("入社可能時期: 20XX年4月")
        XCTAssertEqual(FactQuickAnswer.answer(for: "いつから入社できますか。", facts: facts),
                       "20XX年4月から入社可能です。")
    }

    func testLanguageScoreUsesTheGenericSentence() {
        let facts = store("TOEIC: 850点")
        XCTAssertEqual(FactQuickAnswer.answer(for: "語学のスコアを教えてください。", facts: facts),
                       "TOEICは850点です。")
    }

    /// 値は一切加工しない。しかも値が既に一文なら、テンプレートに押し込まない——
    /// 「御社の規定に従いますを希望しております」は破格で、そのまま読み上げられない。
    func testCompleteSentenceValueIsUsedAsIs() {
        let facts = store("希望年収: 御社の規定に従います")
        XCTAssertEqual(FactQuickAnswer.answer(for: "年収のご希望は？", facts: facts),
                       "御社の規定に従います")
    }

    /// 断片的な値はテンプレートで一文に組む（値そのものは書き換えない）。
    func testFragmentValueIsWrappedButNotRewritten() {
        let facts = store("希望年収: 400万円")
        XCTAssertEqual(FactQuickAnswer.answer(for: "年収のご希望は？", facts: facts),
                       "400万円を希望しております。")
    }

    // MARK: - 不命中（「宁可不命中，绝不错命中」）

    /// 開放質問は絶対に即答経路へ来ない。ここが漏れると、志望動機に一行の事実が
    /// 返って面接が終わる。
    func testOpenEndedQuestionsNeverTakeTheFastPath() {
        let facts = store("希望年収: 400万円\n入社可能時期: 20XX年4月")
        for q in ["志望動機を教えてください。", "学生時代に力を入れたことは？",
                  "自己紹介をお願いします。", "強みと弱みを教えてください。",
                  "最後に何か質問はありますか。"] {
            XCTAssertNil(FactQuickAnswer.answer(for: q, facts: facts), "开放问题被事实速答截胡：\(q)")
        }
    }

    /// 話題は合っているがメモが無い → nil（LLM に任せる）。空振りで黙るのが正解。
    func testNoMatchingNoteFallsThrough() {
        let facts = store("TOEIC: 850点")
        XCTAssertNil(FactQuickAnswer.answer(for: "希望年収はいくらですか。", facts: facts))
    }

    /// メモはあるが質問が別話題 → nil。ラベル側だけの一致では撃たない。
    func testNoteAloneDoesNotFire() {
        let facts = store("希望年収: 400万円")
        XCTAssertNil(FactQuickAnswer.answer(for: "チームでの役割を教えてください。", facts: facts))
    }

    func testEmptyFactsFallThrough() {
        XCTAssertNil(FactQuickAnswer.answer(for: "希望年収は？", facts: FactStore()))
    }

    /// ラベルの無い行は使えない（値だけでは何の数字か分からない）。
    func testUnlabeledNoteIsIgnored() {
        let facts = store("400万円")
        XCTAssertNil(FactQuickAnswer.answer(for: "希望年収は？", facts: facts))
    }

    // MARK: - 分解

    func testLabeledNotesSplitsOnBothColonWidths() {
        let facts = store("希望年収: 400万円\n入社可能時期：20XX年4月\nメモだけの行")
        let labeled = facts.labeledNotes
        XCTAssertEqual(labeled.count, 2, "无标签行必须被丢弃")
        XCTAssertEqual(labeled.first?.label, "希望年収")
        XCTAssertEqual(labeled.first?.value, "400万円")
        XCTAssertEqual(labeled.last?.value, "20XX年4月", "全角冒号也要认")
    }

    /// 事实速答单列一档延迟：并进 cache 会把缓存命中的分布拉平。
    func testLatencyKindIsSeparateFromCache() {
        XCTAssertNotEqual(LatencyMonitor.TurnKind.fact, .cache)
        XCTAssertEqual(LatencyMonitor.TurnKind.fact.rawValue, "fact")
    }

    // MARK: - 同一话题下的多条备忘（Codex review P1-2/P1-3）

    /// 語学グループには TOEIC も JLPT も入る。話題だけで「最初の一件」を返すと、
    /// TOEIC を聞かれて JLPT の値を読み上げる——数字を間違えるのは最悪の失敗。
    func testPicksTheAskedScoreNotTheFirstOneInTheSameTopic() {
        let facts = store("JLPT: N1\nTOEIC: 850点")
        XCTAssertEqual(FactQuickAnswer.answer(for: "TOEICのスコアは？", facts: facts),
                       "TOEICは850点です。")
        XCTAssertEqual(FactQuickAnswer.answer(for: "JLPTは何級ですか。", facts: facts),
                       "JLPTはN1です。")
    }

    /// 現年収と希望年収は同じ compensation グループ。取り違えは論外。
    func testCurrentAndDesiredSalaryAreNotConfused() {
        let facts = store("現年収: 350万円\n希望年収: 400万円")
        XCTAssertEqual(FactQuickAnswer.answer(for: "希望年収はいくらですか。", facts: facts),
                       "400万円を希望しております。")
        // 現年収は事実であって要求ではない——願望形にしてはいけない。
        let current = FactQuickAnswer.answer(for: "現年収を教えてください。", facts: facts)
        XCTAssertEqual(current, "現年収は350万円です。")
        XCTAssertFalse(current?.contains("希望しております") ?? false,
                       "現状の事実が要求額に化けている")
    }

    /// どれとも決められないときは黙る（LLM に回す）。誤答より遅い方がまし。
    func testAmbiguousTopicMatchStaysSilent() {
        let facts = store("JLPT: N1\nTOEIC: 850点")
        XCTAssertNil(FactQuickAnswer.answer(for: "語学力についてどうですか。", facts: facts),
                     "两条都够不上唯一赢家时必须交给 LLM")
    }

    /// 単一のメモしか無い場合は従来どおり撃つ（曖昧さが無い）。
    func testSingleNoteStillAnswersEvenWithLooseWording() {
        let facts = store("TOEIC: 850点")
        XCTAssertEqual(FactQuickAnswer.answer(for: "TOEICは？", facts: facts), "TOEICは850点です。")
    }
}
