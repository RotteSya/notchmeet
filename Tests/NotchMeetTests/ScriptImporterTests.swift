import XCTest
@testable import notchmeet

/// 导入归一化管线：确定性解析优先；覆盖率低时 LLM 只做「分段」（行号/原文子串），
/// 引擎按行号从原文复制重建 —— 逐字性由构造保证，LLM 没有改写答案的通道。
final class ScriptImporterTests: XCTestCase {
    private let cleanDoc = """
    # 自己紹介
    シャと申します。上海で二年働きました。本日はよろしくお願いいたします。

    # 志望動機
    課題を形にする仕事がしたいからです。御社の中立の立場に共感しています。
    """

    /// 面接メモ体：矢印・コロン混在、見出しなし —— 確定性解析ではほぼ拾えない。
    private let messyNotes = """
    面接メモ 6/10 むけ、ざっくり
    まず自己紹介って言われたら→シャです、上海の動画会社で2年働いて、今は立命館の院で経営を学んでます、って感じで軽く。
    志望動機聞かれた場合：課題を形にする仕事がしたい、御社は中立の立場でお客様に一番いい形を組めるから、って言う
    強みは？→相手の困りごとを聞いて、条件を整理して動ける形にする力。万博のインターンの例を出す
    弱み聞かれたら 慎重になりすぎるとこ。今は期限を決めて小さく動くようにしてるって付ける
    最後なにか質問は？→最初の半年で意識すべきことを聞く
    """

    func testCoverageHighForCleanConventionDoc() {
        let r = ScriptImporter.deterministic(cleanDoc)
        XCTAssertGreaterThanOrEqual(r.coverage, 0.8, "clean doc coverage \(r.coverage)")
        XCTAssertEqual(r.entries.count, 2)
    }

    func testCoverageLowForFreeformNotes() {
        let r = ScriptImporter.deterministic(messyNotes)
        XCTAssertLessThan(r.coverage, ScriptImporter.goodCoverage,
                          "messy notes must fall below the gate, got \(r.coverage)")
    }

    /// 行番号レンジ → 原文行の逐字コピー。▼メモ行・空行はレンジ内でも除外。
    func testSegmentsRebuildVerbatimFromLineRanges() {
        let text = """
        自己紹介
        シャと申します。
        ▼キーワード: 上海2年

        上海で二年働きました。
        """
        let raw = #"{"items":[{"q":"自己紹介","a":[2,5]}]}"#
        let entries = ScriptImporter.parseSegments(raw, original: text)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].question, "自己紹介")
        XCTAssertEqual(entries[0].answer, "シャと申します。\n上海で二年働きました。")
    }

    /// 文字列回答は原文の逐字部分列でなければ拒否（LLM の言い換えを機械的に遮断）。
    func testStringAnswersMustBeVerbatimSubstrings() {
        let text = "自己紹介→シャです、上海で2年働いてました、って軽く言う"
        let ok = #"{"items":[{"q":"自己紹介","a":"シャです、上海で2年働いてました"}]}"#
        let rewritten = #"{"items":[{"q":"自己紹介","a":"シャと申します。上海で二年間勤務しておりました。"}]}"#
        XCTAssertEqual(ScriptImporter.parseSegments(ok, original: text).count, 1)
        XCTAssertTrue(ScriptImporter.parseSegments(rewritten, original: text).isEmpty,
                      "a paraphrased answer must be rejected")
    }

    func testSegmentsRejectOutOfRangeLines() {
        let text = "自己紹介\nシャと申します。"
        let raw = #"{"items":[{"q":"自己紹介","a":[2,99]}]}"#
        XCTAssertTrue(ScriptImporter.parseSegments(raw, original: text).isEmpty)
    }

    /// 笔记体的行内前导（「〜きかれたら→」「しぼうどうき: 」）不是要读出的话——
    /// 模型偏好整行 range，前导只能机械剥离。箭头/短冒号头规则；句号后的冒号不误伤。
    func testLeadInPrefixesAreStrippedFromSegmentAnswers() {
        XCTAssertEqual(ScriptImporter.stripLeadIn("自己紹介きかれたら→シャです。上海で二年働きました。"),
                       "シャです。上海で二年働きました。")
        XCTAssertEqual(ScriptImporter.stripLeadIn("しぼうどうき: 課題を形にする仕事がしたいから。"),
                       "課題を形にする仕事がしたいから。")
        // 冒号前已经是完整句（含句读）→ 不是前导，保持原样。
        XCTAssertEqual(ScriptImporter.stripLeadIn("結論です。理由: 三つあります。"),
                       "結論です。理由: 三つあります。")
        // 前导过长（>24字）→ 不剥离（可能是真句子里的箭头）。
        let long = "これはとても長い文章でありなにかの説明をしているだけです→本文"
        XCTAssertEqual(ScriptImporter.stripLeadIn(long), long)
    }

    /// 覆盖率达标时绝不调用 LLM（成本/隐私/离线）。
    func testNormalizeSkipsLLMForCleanDocs() async {
        var called = false
        let r = await ScriptImporter.normalize(cleanDoc) { _, _ in called = true; return "{}" }
        XCTAssertFalse(called, "LLM must not be consulted for a clean doc")
        XCTAssertFalse(r.usedLLM)
        XCTAssertEqual(r.entries.count, 2)
    }

    /// LLM 返回垃圾/失败时安全回退到确定性结果。
    func testNormalizeFallsBackWhenLLMReturnsGarbage() async {
        let r = await ScriptImporter.normalize(messyNotes) { _, _ in "すみません、わかりません" }
        XCTAssertFalse(r.usedLLM)
    }

    /// LLM 分段成功：重建条目走 canonical 渲染→再解析，答案全部是原文逐字。
    func testNormalizeUsesValidLLMSegmentation() async {
        let seg = """
        {"items":[
          {"q":"自己紹介","a":"シャです、上海の動画会社で2年働いて、今は立命館の院で経営を学んでます"},
          {"q":"志望動機","a":"課題を形にする仕事がしたい、御社は中立の立場でお客様に一番いい形を組めるから"},
          {"q":"強みは？","a":"相手の困りごとを聞いて、条件を整理して動ける形にする力。万博のインターンの例を出す"},
          {"q":"弱み","a":"慎重になりすぎるとこ。今は期限を決めて小さく動くようにしてる"},
          {"q":"逆質問","a":"最初の半年で意識すべきことを聞く"}
        ]}
        """
        let r = await ScriptImporter.normalize(messyNotes) { _, _ in seg }
        XCTAssertTrue(r.usedLLM)
        XCTAssertEqual(r.entries.count, 5)
        XCTAssertTrue(r.entries[0].answer.contains("上海の動画会社で2年働いて"))
        // 逐字性：所有答案文本必在原文中出现（空白正規化のうえ）。
        let compactDoc = messyNotes.components(separatedBy: .whitespacesAndNewlines).joined()
        for e in r.entries {
            for line in e.answer.components(separatedBy: "\n") {
                let c = line.components(separatedBy: .whitespacesAndNewlines).joined()
                XCTAssertTrue(compactDoc.contains(c), "not verbatim: \(line)")
            }
        }
    }
}
