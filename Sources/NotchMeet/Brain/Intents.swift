import Foundation

/// The ~15 canonical 就活 intents the question space collapses into (PLAN §7).
/// Used by PreGenerator (what to pre-generate) and as the glance-check label.
enum Intents {
    static let list = [
        "自己紹介", "志望動機", "ガクチカ", "学生時代頑張ったこと", "強み", "弱み",
        "挫折経験", "チームでの役割", "入社後にやりたいこと", "キャリアプラン",
        "逆質問", "なぜこの業界", "他社の選考状況", "趣味・特技", "長所短所",
        // 終盤・最終面接で頻出（実ユーザーの JINS 終面稿から逆算した不足分）。
        "研究内容", "転勤・勤務地", "外国人・語学", "入社意思確認",
    ]

    /// 中文面试的同一组意图（逐条对应日语表，预生成条数与计费口径保持一致）。
    static let listZh = [
        "自我介绍", "应聘动机", "学生时代的经历", "学生时代最投入的事", "优点", "缺点",
        "挫折经历", "团队中的角色", "入职后想做的事", "职业规划",
        "反向提问", "为什么选这个行业", "其他公司的面试进展", "兴趣爱好", "优缺点",
        "研究内容", "外派与工作地点", "语言能力", "入职意愿确认",
    ]

    static func list(for language: InterviewLanguage) -> [String] {
        switch language {
        case .japanese: list
        case .chinese: listZh
        }
    }
}
