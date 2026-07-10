import Foundation

struct RouteDecision {
    let intent: String
    let matchedAnswer: String?   // non-nil only on a confident cache hit
}

/// Decides intent + whether a cached answer truly matches (PLAN §7). Conservative:
/// when unsure → no match (live generation handles it). NullRouter always misses.
protocol Router: AnyObject {
    func route(question: String, candidates: [BankEntry]) async throws -> RouteDecision
}

final class NullRouter: Router {
    func route(question: String, candidates: [BankEntry]) async throws -> RouteDecision {
        RouteDecision(intent: "", matchedAnswer: nil)
    }
}

/// Single fast LLM call returns BOTH the intent and the match index (merged, per
/// §7 / §14.3 — no serial two-hop). Biased to answer `null` unless certain.
final class LLMRouter: Router {
    /// The match criterion is ANSWERABILITY, not sameness: interviewers never phrase a
    /// question exactly like the script heading (「就活の軸を教えてください」 vs 稿の
    /// 「就職活動の軸」). "同じことを聞いている" made the small model reject nearly every
    /// paraphrase — the field reports of "answer isn't my script" trace back to it.
    /// Uncertainty still means null: a wrong verbatim answer read aloud is worse than a
    /// grounded live one.
    static func systemPrompt() -> String {
        let intentList = Intents.list.joined(separator: "、")
        return """
        あなたは面接質問のルーターです。出力は JSON のみ。説明禁止。
        形式: {"intent":"<候補意図>","match":<候補番号 or null>}
        ルール:
        - intent は次から最も近いものを1つ: \(intentList)
        - match は、その候補の準備済み回答を『この質問への返答としてそのまま読み上げて成立する』場合のみその番号。質問の言い回しが違っても、聞かれている中身に回答が正面から答えていれば match とする。
        - 語彙が違っても指す内容が同じなら match（例: ビザ＝在留資格、うち・御社＝当社、転勤＝勤務地）。
        - 面接官が「あなたから何か質問は？」型の質問をした場合は、準備した逆質問の候補が該当する。
        - 複数の候補が該当する場合は、最も小さい番号を選ぶ（ユーザー作成の原稿を優先）。
        - 回答がズレる・部分的にしか答えない・自信がない場合は match は必ず null。
        """
    }

    /// Judging answerability requires SEEING the answer: each candidate carries the
    /// opening of its prepared answer, capped so five candidates stay a few hundred
    /// chars (prompt-processing cost is negligible against the 3s SLA).
    static func candidateBlock(_ candidates: [BankEntry]) -> String {
        var cand = ""
        for (i, e) in candidates.enumerated() {
            let head = e.answer.count > 60 ? e.answer.prefix(60) + "…" : Substring(e.answer)
            cand += "[\(i)] 質問: \(e.question)\n    回答冒頭: \(head)\n"
        }
        return cand
    }

    func route(question: String, candidates: [BankEntry]) async throws -> RouteDecision {
        let cand = Self.candidateBlock(candidates)
        let user = "質問: \(question)\n\n候補:\n\(cand.isEmpty ? "(なし)" : cand)"
        let raw = try await FastLLM.complete(system: Self.systemPrompt(), user: user, maxTokens: 80)
        return parse(raw, candidates: candidates)
    }

    func parse(_ raw: String, candidates: [BankEntry]) -> RouteDecision {
        // tolerate code fences / surrounding text — extract the first {...}
        guard let lo = raw.firstIndex(of: "{"), let hi = raw.lastIndex(of: "}"),
              let data = String(raw[lo...hi]).data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return RouteDecision(intent: "", matchedAnswer: nil)
        }
        let intent = (o["intent"] as? String) ?? ""
        // Small domestic models occasionally quote the index ({"match":"0"}) — a typed
        // miss here silently discards the user's verbatim answer, so accept both.
        let idx = (o["match"] as? Int) ?? (o["match"] as? String).flatMap(Int.init)
        var answer: String?
        if let idx, idx >= 0, idx < candidates.count {
            answer = candidates[idx].answer
        }
        return RouteDecision(intent: intent, matchedAnswer: answer)
    }
}
