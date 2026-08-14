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
    static func answer(for question: String, facts: FactStore,
                       language: InterviewLanguage = Settings.interviewLanguage) -> String? {
        let q = QuestionMatcher.normalized(question)
        let questionTopics = QuestionMatcher.topics(in: q).intersection(factualTopics)
        guard !questionTopics.isEmpty else { return nil }

        // 同一话题下常常有多条备忘（TOEIC 与 JLPT 同属語学、現年収 与 希望年収 同属年収）。
        // 只按话题取「第一条」＝按文件顺序回答，问 TOEIC 会答出 JLPT 的值。
        // 所以话题只用来缩小范围，最终必须由**标签本身与问题的字面重合**决出唯一赢家；
        // 分不出高下就返回 nil 交给 LLM——错答一个数字比慢一点严重得多。
        let candidates = facts.labeledNotes.filter { label, _ in
            !QuestionMatcher.topics(in: QuestionMatcher.normalized(label))
                .intersection(questionTopics).isEmpty
        }
        guard !candidates.isEmpty else { return nil }
        // 候补只有一条＝没有歧义可言，照旧回答。「語学のスコアは？」对上唯一的
        // TOEIC 备忘正是这条路径——要求字面重合会把它误伤掉。
        if candidates.count == 1 {
            return sentence(label: candidates[0].label, value: candidates[0].value, language: language)
        }

        let scored = candidates.map { (note: $0, score: labelAffinity(QuestionMatcher.normalized($0.label), in: q)) }
        let best = scored.max { $0.score < $1.score }!
        guard best.score > 0 else { return nil }                       // 谁都对不上 → 不撃つ
        guard scored.filter({ $0.score == best.score }).count == 1 else { return nil }  // 并列 → 不撃つ
        return sentence(label: best.note.label, value: best.note.value, language: language)
    }

    /// 标签与问题的字面贴合度。整标签出现在问题里最强（希望年収 ⊂「希望年収は？」）；
    /// 否则按标签里出现在问题中的最长片段计——「現年収」与「希望年収」都含「年収」，
    /// 只有把整标签算进去才能把它们分开。
    private static func labelAffinity(_ label: String, in question: String) -> Int {
        guard !label.isEmpty else { return 0 }
        if question.contains(label) { return label.count * 10 }
        let chars = Array(label)
        var longest = 0
        for start in chars.indices {
            for end in stride(from: chars.count, to: start, by: -1) where end - start > longest {
                if question.contains(String(chars[start..<end])) { longest = end - start; break }
            }
        }
        return longest >= 2 ? longest : 0        // 单字重合太弱，不作数
    }

    /// ラベルと値だけから敬語一文を組む。値は**一切加工しない**——「400万円（応相談）」と
    /// 書いてあればそのまま使う。テンプレートは読み上げて自然になるものだけを特別扱いし、
    /// それ以外は「〜は〜です」の汎用形（どのラベルでも文法的に成立する）。
    private static func sentence(label: String, value: String,
                                 language: InterviewLanguage) -> String? {
        // 中文面试 + 日语写的事实（老用户的「希望年収: 御社の規定に従います」）：
        // 中日混排句照读必穿帮，且即答命中即定稿、没有生成兜底来纠正——宁可不命中，
        // 返回 nil 交给 LLM 拿事实做 grounding 以中文重述。假名是可靠的日语信号；
        // 纯汉字的日语标签（希望年収）可读性尚可，保留通用模板。
        if language == .chinese, containsKana(label) || containsKana(value) { return nil }

        // 値そのものが既に一文なら、テンプレートに押し込まない。
        // 「希望年収: 御社の規定に従います」を「〜を希望しております」に嵌めると
        // 「御社の規定に従いますを希望しております」という破格になる。
        if isCompleteSentence(value) { return value }

        let l = QuestionMatcher.normalized(label)
        switch language {
        case .chinese:
            // 通用形「〜是〜。」对任何标签都成句（入职时间是2027年4月。），
            // 不需要日语那套愿望形/入社形的特判——特判是敬语语法逼出来的。
            if l.contains("入社") || l.contains("入职") || l.contains("到岗") {
                return "\(value)起可以入职。"
            }
            return "\(label)是\(value)。"
        case .japanese:
            break
        }
        if l.contains("入社") || l.contains("着任") || l.contains("いつから") {
            return "\(value)から入社可能です。"
        }
        // 「希望」を明示するラベルだけ願望形にする。`現年収: 350万円` を
        // 「350万円を希望しております」と読み上げると、現状の事実が要求額に化ける——
        // 面接で最も誤解されたくない数字でそれをやってはいけない。
        let wantsDesired = ["希望", "想定", "期待", "第一希望"].contains { l.contains($0) }
        if wantsDesired, l.contains("年収") || l.contains("給与") || l.contains("給料") || l.contains("報酬") {
            return "\(value)を希望しております。"
        }
        return "\(label)は\(value)です。"
    }

    /// 日本語専用の文字（かな）を含むか。中文即答の混排ガードに使う。
    private static func containsKana(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x3040...0x30ff).contains($0.value) }
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
