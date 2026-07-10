import Foundation

/// Import-time normalization for arbitrary user documents (PLAN §5 の入口強化).
///
/// Users paste anything — Word/Notion exports, transcript-style notes, colon/arrow
/// separated memos. Strategy is layered so the verbatim promise survives:
///  1. `ScriptParser` (deterministic, offline) runs first — battle-tested on real
///     整合稿/JINS-style docs; when its COVERAGE of the document is good, done.
///  2. Otherwise the LLM is asked to SEGMENT, never to rewrite: it returns line
///     ranges (or verbatim substrings) pointing INTO the original text, and entries
///     are rebuilt by copying those lines. A paraphrased answer physically cannot
///     survive: string answers must be substrings of the original, ranges are
///     bounds-checked, and a result that doesn't beat the deterministic coverage
///     is discarded. Gated on the same privacy toggle as all other LLM traffic.
enum ScriptImporter {
    struct Result {
        let entries: [BankEntry]
        let coverage: Double
        let usedLLM: Bool
    }

    /// Below this share of document content captured into entries, the parse likely
    /// missed the document's structure (real 整合稿 measure ~0.8; note-style ~0.1).
    static let goodCoverage = 0.55

    typealias Completion = (_ system: String, _ user: String) async throws -> String

    // MARK: - Deterministic leg

    static func coverage(of entries: [BankEntry], in text: String) -> Double {
        let content = contentChars(text)
        guard content > 0 else { return 0 }
        let captured = entries.reduce(0) { $0 + $1.question.count + $1.answer.count }
        return min(1, Double(captured) / Double(content))
    }

    private static func contentChars(_ text: String) -> Int {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .reduce(0) { $0 + $1.count }
    }

    static func deterministic(_ text: String) -> Result {
        let entries = ScriptParser.parse(text)
        return Result(entries: entries, coverage: coverage(of: entries, in: text), usedLLM: false)
    }

    // MARK: - Normalization pipeline

    /// LLM leg availability: same privacy gate as live generation/routing, plus a key.
    static var isLLMAvailable: Bool {
        Settings.sendContextToLLM && ProviderRegistry.llmResolution() != LLMResolution.none
    }

    /// `complete` is injectable for tests; nil wires FastLLM when available.
    static func normalize(_ text: String, complete: Completion? = nil) async -> Result {
        let det = deterministic(text)
        if det.coverage >= goodCoverage { return det }   // coverage is the signal; a
        // 2-entry doc at 0.9 coverage is simply a small, clean script.
        guard text.count < 60_000 else { return det }   // pathological paste — stay offline
        let transport: Completion? = complete ?? (isLLMAvailable
            ? { sys, user in try await FastLLM.complete(system: sys, user: user, maxTokens: 2048) }
            : nil)
        guard let transport,
              let llm = await llmSegmented(text, complete: transport),
              llm.coverage > det.coverage,
              llm.entries.count >= max(1, det.entries.count) else { return det }
        NSLog("[import] LLM segmentation accepted: %d entries, coverage %.2f (det %.2f)",
              llm.entries.count, llm.coverage, det.coverage)
        return llm
    }

    // MARK: - LLM segmentation (structure only — text is copied from the original)

    static let segmentSystemPrompt = """
    あなたは面接原稿の構造解析器です。行番号付きの原稿から、質問と回答のペアを抽出します。出力は JSON のみ。説明禁止。
    形式: {"items":[{"q":"<質問>","a":[開始行,終了行]},{"q":"<質問>","a":"<回答文>"}]}
    ルール:
    - 回答が独立した行にある場合は、行番号の範囲 [開始行,終了行] を使う。
    - 質問と回答が同じ行にある場合（「自己紹介→シャです…」「志望動機: 課題を…」など）は、回答部分だけを原文から一字一句そのまま抜き出して a に入れる。「〜きかれたら→」「〜の場合:」のような前置きや話者ラベルは a に含めない。
    - 回答を書き換え・要約・補完しない。原文にない文を作らない。
    - q はその行から質問・話題を短く抜き出す。
    - 日付・タイトル・メモ・キーワード行など、Q&Aでないものは含めない。
    """

    static func llmSegmented(_ text: String, complete: Completion) async -> Result? {
        let lines = normalizedLines(text)
        let numbered = lines.enumerated().map { "\($0.offset + 1)|\($0.element)" }
            .joined(separator: "\n")
        guard let raw = try? await complete(segmentSystemPrompt, "原稿:\n\(numbered)") else {
            return nil
        }
        let rebuilt = parseSegments(raw, original: text)
        guard !rebuilt.isEmpty else { return nil }
        // Render to the canonical convention and re-parse so ALL parser hygiene
        // (label/number stripping, ▼ removal, dedupe rules) applies uniformly —
        // the stored script is exactly what a hand-written canonical doc would be.
        let entries = ScriptParser.parse(conventionText(rebuilt))
        guard !entries.isEmpty else { return nil }
        return Result(entries: entries, coverage: coverage(of: entries, in: text), usedLLM: true)
    }

    /// Rebuild entries from the LLM's segmentation, copying from the ORIGINAL text.
    /// Every acceptance path is mechanical: ranges are bounds-checked; string answers
    /// must be whitespace-normalized substrings of the original document.
    static func parseSegments(_ raw: String, original: String) -> [BankEntry] {
        let lines = normalizedLines(original)
        guard let lo = raw.firstIndex(of: "{"), let hi = raw.lastIndex(of: "}"),
              let data = String(raw[lo...hi]).data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = obj["items"] as? [[String: Any]] else { return [] }
        let compactDoc = compact(original)

        var out: [BankEntry] = []
        for item in items {
            guard let q = (item["q"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !q.isEmpty, q.count <= 120 else { continue }
            let answer: String
            if let range = item["a"] as? [Any], range.count == 2,
               let start = intValue(range[0]), let end = intValue(range[1]) {
                guard start >= 1, end >= start, end <= lines.count else { return [] }
                answer = lines[(start - 1)...(end - 1)]
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty && !$0.hasPrefix("▼") }
                    .joined(separator: "\n")
            } else if let s = item["a"] as? String {
                let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !t.isEmpty, compactDoc.contains(compact(t)) else { return [] }
                answer = t
            } else {
                continue
            }
            let cleaned = stripLeadIn(answer)
            guard !cleaned.isEmpty else { continue }
            out.append(BankEntry(id: "import-\(out.count + 1)", intent: q,
                                 question: q, answer: cleaned, locked: true))
        }
        return out
    }

    /// Canonical import convention (same shape `ScriptStore.conventionText` re-exports).
    static func conventionText(_ entries: [BankEntry]) -> String {
        entries.map { "# \($0.question)\n\($0.answer)" }.joined(separator: "\n\n")
    }

    /// Note-style answers open with a lead-in the candidate never says aloud
    /// (「自己紹介きかれたら→」「しぼうどうき: 」). The model prefers whole-line ranges,
    /// so the lead-in is stripped mechanically: a SHORT head (≤24 chars, no sentence
    /// punctuation — i.e. not yet a real sentence) ending in an arrow or colon.
    static func stripLeadIn(_ answer: String) -> String {
        var lines = answer.components(separatedBy: "\n")
        guard var first = lines.first else { return answer }
        for marker in ["→", "：", ": "] {
            guard let r = first.range(of: marker) else { continue }
            let head = first[..<r.lowerBound]
            if head.count <= 24, !head.contains(where: { "。．！？!?".contains($0) }) {
                first = String(first[r.upperBound...])
                    .trimmingCharacters(in: .whitespaces)
                break
            }
        }
        lines[0] = first
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Helpers

    private static func intValue(_ any: Any) -> Int? {
        (any as? Int) ?? (any as? String).flatMap(Int.init)
    }

    private static func compact(_ s: String) -> String {
        s.components(separatedBy: .whitespacesAndNewlines).joined()
    }

    private static func normalizedLines(_ text: String) -> [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
    }
}
