import Foundation

/// Similarity / coverage for speculative turns (PLAN §7, revised).
///
/// Reuse is allowed only when the *final* is already covered by the speculative
/// question. The opposite direction (`spec ⊂ final`) would treat "Q1" as a match
/// for "Q1+Q2" and skip answering the second question.
enum TurnSpeculation {
    /// Fraction of the final's content tokens that also appear in `spec`.
    /// Chinese tokens are character bigrams (`LLMRouter.contentWords`); Japanese
    /// tokens are kanji / katakana / latin runs. Same helper the deictic veto uses.
    static func coverage(spec: String, final: String,
                         language: InterviewLanguage) -> Double {
        let a = LLMRouter.contentWords(spec, language: language)
        let b = LLMRouter.contentWords(final, language: language)
        if b.isEmpty {
            let ns = normalize(spec), nf = normalize(final)
            return ns.isEmpty && nf.isEmpty ? 1 : (ns == nf ? 1 : 0)
        }
        if a.isEmpty { return 0 }
        return Double(a.intersection(b).count) / Double(b.count)
    }

    /// Reuse the in-flight speculative turn only when the final's content is
    /// almost entirely already in the speculative question.
    static func covers(spec: String, final: String,
                       language: InterviewLanguage) -> Bool {
        coverage(spec: spec, final: final, language: language) >= 0.9
    }

    static func normalize(_ raw: String) -> String {
        QuestionMatcher.normalized(raw)
    }
}
