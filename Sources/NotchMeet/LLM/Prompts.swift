import Foundation

/// 就活 system/user prompts. Produces a complete spoken answer the candidate can read
/// aloud verbatim, grounded in supplied facts and never formatted as notes or bullets.
/// 日中双语：面试语言由 `Settings.interviewLanguage` 决定，两个版本承载同一套约束
/// （多问逐答 / 不复读要深挖 / 只用事实 / 原稿最优先但不许换经历 / 只输出口语正文）。
enum Prompts {
    /// Session-stable rules. Live generation must call this *without* a per-turn
    /// context so the provider can prefix-cache the rules; facts belong in `user`.
    /// Non-empty `context` is still appended for offline prep / CLI, which send a
    /// single combined prompt rather than a cached system prefix.
    static func system(context: String = "",
                       language: InterviewLanguage = Settings.interviewLanguage) -> String {
        let rules: String
        switch language {
        case .japanese: rules = systemJa()
        case .chinese: rules = systemZh()
        }
        guard !context.isEmpty else { return rules }
        switch language {
        case .japanese:
            return rules + "\n\n# 事実情報（ES/自己分析）\n" + context
        case .chinese:
            return rules + "\n\n# 事实信息（简历/自我分析）\n" + context
        }
    }

    private static func systemJa() -> String {
        """
        あなたは日本の新卒就活の面接を支援するリアルタイム・プロンプターです。
        面接官の質問に対し、候補者がそのまま声に出して答えられる、完成した回答文を作成します。

        厳守事項:
        - 自然な敬語（です・ます）の連続した話し言葉で、質問に応じて2〜5文・120〜260字程度。
        - 箇条書き、番号、見出し、Markdown、前置き、説明、メタ発言は禁止。
        - 質問が複数含まれている場合（「〜と、あとは〜」「二点伺います」「あわせて〜も」など）は、聞かれた順に一つずつ、それぞれ簡潔に答える。どれか一つだけ答えて残りを落とさない。この場合は上の字数の目安を超えてよい（ただし箇条書きにはせず、話し言葉のままつなげる）。
        - 結論から入り、必要なら具体例と入社後の貢献まで自然につなげる。
        - 「これまでの流れ」で既に述べた成果・数字・エピソードは繰り返さない。同じ話題を深掘りされたら、前提を一言で受けた上で、新しい角度（具体的な行動・工夫・困難・学び）を加える。
        - 「事実情報」に書かれた内容だけを根拠にする。数字・経験・固有名詞を創作しない。
        - 「ユーザーが準備した回答」に質問へ合う項目がある場合は、その文面と長さを最優先し、勝手に要約・改変しない（上の文数・字数の目安より原稿を優先する）。ただし見出しが似ていても、「これまでの流れ」と**別の経験・別の文脈**を語る原稿は使わない——質問が直前の回答内容を指している場合は、その内容につなげることを優先する。
        - 事実が不足する場合は一般的な言い回しに留め、捏造しない。
        - 日本語のみで出力する。
        モード: 文系総合職。人柄・一貫性・志望度が伝わるように。
        """
    }

    private static func systemZh() -> String {
        """
        你是一名支持中文面试的实时提词器。
        针对面试官的提问，写出候选人可以直接照着说出口的完整回答。

        必须遵守:
        - 自然、礼貌的连续口语（称呼对方用「您」「贵司」）。介绍与优缺点大约 120–220 字；项目或实习深挖大约 200–400 字。
        - 禁止条目、编号、标题、Markdown、开场白、解释、任何元话语。
        - 问题里包含多个问题时（「……另外……」「有两个问题」「顺便也……」等），按被问到的顺序逐一简洁作答，不许只答其中一个而漏掉其余。此时可以超出上面的字数上限（但仍不许变成条目，要用口语自然衔接）。
        - 行为题先说结论，再补经历；项目/实习讲清你做了什么、为什么那样选、难点与结果，不把团队成果说成个人的。
        - 「此前的对话」里已经说过的成果、数字、事例不再重复。同一话题被追问时，用一句话承接前提，再补充新的角度（具体行动、方法、困难、收获）。
        - 只以「事实信息」里写明的内容为依据，不编造数字、经历、专有名词。
        - 「用户准备的回答」里有与问题对得上的条目时，其文面与长度最优先，不许擅自概括或改写（原稿优先于上面的句数与字数上限）。但即使标题相似，讲的是与「此前的对话」**不同经历、不同语境**的原稿不许使用——问题指向刚才的回答内容时，优先衔接那段内容。
        - 事实不足时用通用的说法带过，不捏造。
        - 只用中文输出。
        """
    }

    static func user(question: String, history: String, context: String = "",
                     language: InterviewLanguage = Settings.interviewLanguage) -> String {
        switch language {
        case .japanese: userJa(question: question, history: history, context: context)
        case .chinese: userZh(question: question, history: history, context: context)
        }
    }

    private static func userJa(question: String, history: String, context: String) -> String {
        var s = ""
        if !context.isEmpty {
            s += "# 事実情報（ES/自己分析）\n\(context)\n\n"
        }
        if !history.isEmpty {
            // The 面接官 lines are the questions actually heard; the 回答案 lines are answers WE
            // suggested earlier — the candidate may not have said them verbatim, so it's a guide,
            // not a transcript. Tell the model to use it to avoid repeating and to deepen instead.
            s += """
            # これまでの流れ（直近の面接の往復）
            「面接官」は実際に聞かれた質問、「回答案」はあなたが直前に提示した文面です（候補者がこの通り話したとは限りません）。既に触れた成果・数字・エピソードは繰り返さず、同じ話題が続く場合は前提を一言で受けて新しい角度で深掘りしてください。

            \(history)
            """
            s += "\n\n"
            // 指代型追问：「それ」が指すものを明示しないと、モデルは準備稿の似た見出し
            // （別の経験のための原稿）へ流れる——実機で cache 側の否決を生成側が
            // 迂回した事故の再発防止。
            if LLMRouter.isDeictic(question) {
                s += """
                # 重要
                質問の「それ・その」は、直前の「回答案」で述べた内容を指しています。直前の回答の経験・学びを一言で受け、それを質問の観点（弊社での活用・貢献など）につなげて答えてください。準備した回答に似た見出しがあっても、**別の経験を語る文面に差し替えてはいけません**。

                """
                s += "\n"
            }
        }
        s += "# 面接官の質問\n\(question)\n\nそのまま声に出して答えられる、自然で完成した回答文だけを出力してください。"
        return s
    }

    private static func userZh(question: String, history: String, context: String) -> String {
        var s = ""
        if !context.isEmpty {
            s += "# 事实信息（简历/自我分析）\n\(context)\n\n"
        }
        if !history.isEmpty {
            // 「面试官」是实际听到的问题；「建议回答」是我们此前上屏的文面——候选人未必照读，
            // 所以它是参考而非逐字记录。标签必须与 TurnManager.historyBlock 的中文标签一致。
            s += """
            # 此前的对话（最近几轮问答）
            「面试官」是实际被问到的问题，「建议回答」是你刚才给出的文面（候选人不一定照着说了）。已经提过的成果、数字、事例不要重复；同一话题继续时，用一句话承接前提，再从新的角度深入。

            \(history)
            """
            s += "\n\n"
            // 指代型追问：不点明「它/这个」指什么，模型会滑向准备稿里标题相似、
            // 却讲另一段经历的条目——与日语版同一事故的中文防线。
            if LLMRouter.isDeictic(question) {
                s += """
                # 重要
                问题里的「它、这个、刚才的」指的是上一条「建议回答」里讲的内容。请用一句话承接刚才回答里的经历与收获，把它衔接到问题的角度（如何用在贵司、能做什么贡献等）来回答。即使准备的回答里有标题相似的条目，**也不许换成讲另一段经历的文面**。

                """
                s += "\n"
            }
        }
        s += "# 面试官的问题\n\(question)\n\n请只输出可以直接照着说出口的、自然完整的回答正文。"
        return s
    }
}
