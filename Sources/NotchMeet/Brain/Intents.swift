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
}
