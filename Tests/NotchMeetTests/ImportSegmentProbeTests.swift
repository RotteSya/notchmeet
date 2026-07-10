import XCTest
@testable import notchmeet

/// 导入 LLM 分段验收探针（默认跳过——真实网络）：
///
///     FI_IMPORT_PROBE=1 [TZ=Asia/Shanghai] swift test --filter ImportSegmentProbe
///
/// 输入是刻意「千奇百怪」的面接メモ体（矢印・コロン混在、无标题、Q/A 同行），
/// 确定性解析拾不到 → 走 LLM 分段。验收：≥4 条、答案全部是原文逐字（空白正规化）。
final class ImportSegmentProbeTests: XCTestCase {
    func testMessyNotesSegmentToVerbatimEntries() async throws {
        guard ProcessInfo.processInfo.environment["FI_IMPORT_PROBE"] == "1" else {
            throw XCTSkip("import probe disabled — set FI_IMPORT_PROBE=1 to run against the real network")
        }
        guard ProviderRegistry.llmResolution() != LLMResolution.none else {
            throw XCTSkip("no LLM key configured")
        }

        let messy = """
        めも 一次面接よう（あとで整理する）
        自己紹介きかれたら→シャです。上海の動画会社で二年、アカウント運用をやってました。いまは立命館の院で経営を学んでいます。よろしくお願いします、まで。
        しぼうどうき: 課題を形にする仕事がしたいから。御社は中立の立場で、お客様に一番いい組み合わせを提案できるところに惹かれた、と言う
        つよみ→相手の困りごとを聞いて条件を整理して、動ける形にまとめる力です。万博インターンで五か国チームをまとめて最優秀賞。
        よわみ 慎重になりすぎて情報を集めすぎるとこ。いまは期限を決めて小さく動くようにしています、でしめる
        てんきんOKか聞かれたら→問題ないです、事業内容を優先したいので東京でも前向きです
        ぎゃくしつもん、最初の半年で意識すべき行動があれば教えてください、を聞く
        """

        let det = ScriptImporter.deterministic(messy)
        XCTAssertLessThan(det.coverage, ScriptImporter.goodCoverage,
                          "fixture must actually be messy (det coverage \(det.coverage))")

        let r = await ScriptImporter.normalize(messy)
        NSLog("[import-probe] usedLLM=%d entries=%d coverage=%.2f (det %.2f)",
              r.usedLLM ? 1 : 0, r.entries.count, r.coverage, det.coverage)
        for e in r.entries {
            NSLog("[import-probe]   Q: %@ / A(%d字): %@…", e.question, e.answer.count,
                  String(e.answer.prefix(24)))
        }
        XCTAssertTrue(r.usedLLM, "messy notes must route through LLM segmentation")
        XCTAssertGreaterThanOrEqual(r.entries.count, 4)

        // 逐字性の機械検証：全答案行が原文に存在する（空白正規化）。
        let compactDoc = messy.components(separatedBy: .whitespacesAndNewlines).joined()
        for e in r.entries {
            for line in e.answer.components(separatedBy: "\n") where !line.isEmpty {
                let c = line.components(separatedBy: .whitespacesAndNewlines).joined()
                XCTAssertTrue(compactDoc.contains(c), "not verbatim: \(line)")
            }
        }
    }
}
