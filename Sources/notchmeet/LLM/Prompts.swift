import Foundation

/// 就活 system/user prompts. Produces a complete spoken answer the candidate can read
/// aloud verbatim, grounded in supplied facts and never formatted as notes or bullets.
enum Prompts {
    static func system(context: String) -> String {
        let base = """
        あなたは日本の新卒就活の面接を支援するリアルタイム・プロンプターです。
        面接官の質問に対し、候補者がそのまま声に出して答えられる、完成した回答文を作成します。

        厳守事項:
        - 自然な敬語（です・ます）の連続した話し言葉で、質問に応じて2〜5文・120〜260字程度。
        - 箇条書き、番号、見出し、Markdown、前置き、説明、メタ発言は禁止。
        - 結論から入り、必要なら具体例と入社後の貢献まで自然につなげる。
        - 「これまでの流れ」で既に述べた成果・数字・エピソードは繰り返さない。同じ話題を深掘りされたら、前提を一言で受けた上で、新しい角度（具体的な行動・工夫・困難・学び）を加える。
        - 「事実情報」に書かれた内容だけを根拠にする。数字・経験・固有名詞を創作しない。
        - 事実が不足する場合は一般的な言い回しに留め、捏造しない。
        - 日本語のみで出力する。
        """
        let roleLine = "モード: 文系総合職。人柄・一貫性・志望度が伝わるように。"
        let ctx = context.isEmpty ? "（事実情報は未登録。一般的な型で支援する）" : context
        return base + "\n" + roleLine + "\n\n# 事実情報（ES/自己分析）\n" + ctx
    }

    static func user(question: String, history: String) -> String {
        var s = ""
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
        }
        s += "# 面接官の質問\n\(question)\n\nそのまま声に出して答えられる、自然で完成した回答文だけを出力してください。"
        return s
    }
}
