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
    func route(question: String, candidates: [BankEntry]) async throws -> RouteDecision {
        let intentList = Intents.list.joined(separator: "、")
        var cand = ""
        for (i, e) in candidates.enumerated() {
            cand += "[\(i)] (\(e.intent)) \(e.question)\n"
        }
        let sys = """
        あなたは面接質問のルーターです。出力は JSON のみ。説明禁止。
        形式: {"intent":"<候補意図>","match":<候補番号 or null>}
        ルール:
        - intent は次から最も近いものを1つ: \(intentList)
        - match は、候補の中に『質問と"同じことを聞いている"もの』がある場合のみその番号。
        - 複数の候補が該当する場合は、最も小さい番号を選ぶ（ユーザー作成の原稿を優先）。
        - 少しでも違う/自信がなければ match は必ず null（保守的に）。
        """
        let user = "質問: \(question)\n\n候補:\n\(cand.isEmpty ? "(なし)" : cand)"
        let raw = try await FastLLM.complete(system: sys, user: user, maxTokens: 80)
        return parse(raw, candidates: candidates)
    }

    private func parse(_ raw: String, candidates: [BankEntry]) -> RouteDecision {
        // tolerate code fences / surrounding text — extract the first {...}
        guard let lo = raw.firstIndex(of: "{"), let hi = raw.lastIndex(of: "}"),
              let data = String(raw[lo...hi]).data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return RouteDecision(intent: "", matchedAnswer: nil)
        }
        let intent = (o["intent"] as? String) ?? ""
        var answer: String?
        if let idx = o["match"] as? Int, idx >= 0, idx < candidates.count {
            answer = candidates[idx].answer
        }
        return RouteDecision(intent: intent, matchedAnswer: answer)
    }
}
