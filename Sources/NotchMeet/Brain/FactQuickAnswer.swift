import Foundation

/// 数字・条件系の質問に対する**確定的な**即答（审计 #19）。
///
/// 「希望年収は？」「入社可能時期は？」「TOEIC は？」——面接官が最も即答を期待し、
/// 曖昧に答えると内容以前に「準備していない」と読まれる一群。ところが従来はこれらも
/// 開放質問と同じ経路（router LLM ＋ live 生成の競走）を通っていた上に、生成側は
/// 「数字・固有名詞を創作しない」と縛られているため、事実が無ければ数字の入らない
/// 一般論しか出せなかった。しかも遅い。
///
/// ここはネットワークを一切使わない：ユーザーが「経歴・事実」に書いたメモをそのまま
/// 一文に組み立てて即上屏する。LLM に書き換えさせる通路は作らない（ScriptParser と
/// 同じ原則——事実はユーザーが書いたものであって、モデルが整えてよいものではない）。
enum FactQuickAnswer {

    /// 即答を許す話題。ここに挙げたものだけが対象＝「宁可不命中，绝不错命中」。
    /// 開放質問（志望動機・ガクチカ…）は絶対にここへ来ない。
    private static let factualTopics: Set<String> = ["compensation", "start_date", "language_score"]

    /// 質問にぴったり合うメモがあれば、そのまま読み上げられる一文を返す。
    ///
    /// 判定は二重：質問の話題タグとメモのラベルの話題タグが**同じ事実系グループ**で
    /// 重なること。片方だけでは撃たない。
    static func answer(for question: String, facts: FactStore) -> String? {
        let questionTopics = QuestionMatcher.topics(in: QuestionMatcher.normalized(question))
            .intersection(factualTopics)
        guard !questionTopics.isEmpty else { return nil }

        for (label, value) in facts.labeledNotes {
            let labelTopics = QuestionMatcher.topics(in: QuestionMatcher.normalized(label))
            guard !labelTopics.intersection(questionTopics).isEmpty else { continue }
            return sentence(label: label, value: value)
        }
        return nil
    }

    /// ラベルと値だけから敬語一文を組む。値は**一切加工しない**——「400万円（応相談）」と
    /// 書いてあればそのまま使う。テンプレートは読み上げて自然になるものだけを特別扱いし、
    /// それ以外は「〜は〜です」の汎用形（どのラベルでも文法的に成立する）。
    private static func sentence(label: String, value: String) -> String {
        // 値そのものが既に一文なら、テンプレートに押し込まない。
        // 「希望年収: 御社の規定に従います」を「〜を希望しております」に嵌めると
        // 「御社の規定に従いますを希望しております」という破格になる。
        if isCompleteSentence(value) { return value }

        let l = QuestionMatcher.normalized(label)
        if l.contains("入社") || l.contains("着任") || l.contains("いつから") {
            return "\(value)から入社可能です。"
        }
        if l.contains("年収") || l.contains("給与") || l.contains("給料") || l.contains("報酬") {
            return "\(value)を希望しております。"
        }
        return "\(label)は\(value)です。"
    }

    /// 値が既に敬体の一文かどうか。句点で終わる、または です／ます 系で終わるもの。
    private static func isCompleteSentence(_ value: String) -> Bool {
        let t = value.trimmingCharacters(in: .whitespaces)
        if t.hasSuffix("。") { return true }
        for tail in ["です", "ます", "ました", "ません", "ございます"] where t.hasSuffix(tail) {
            return true
        }
        return false
    }
}
