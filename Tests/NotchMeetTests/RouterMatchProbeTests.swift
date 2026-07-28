import XCTest
@testable import notchmeet

/// 路由判据验收探针（默认跳过——真实网络）：
///
///     FI_ROUTER_PROBE=1 [TZ=Asia/Shanghai] swift test --filter RouterMatchProbe
///
/// 背景：实机反馈「转录的问题没错、稿子里有对应条目，但出的不是准备的回答」。旧判据
/// 『同じことを聞いている』对转述问法（面试官永远不会照稿提问）过度保守，命中率趋零。
/// 本探针用「合成面接稿 + 转述问法」直接打真实 FastLLM，量化：
///   - answerable 组：语义可答的转述 → 期望 match（宽松线 ≥60%，防 flaky）
///   - control 组：稿子里没有的问题 → 必须全部 null（保守性不能丢）
final class RouterMatchProbeTests: XCTestCase {
    private func entry(_ q: String, _ a: String) -> BankEntry {
        BankEntry(id: q, intent: q, question: q, answer: a, locked: true)
    }

    private var script: [BankEntry] {
        [
            entry("自己紹介", "田中太郎と申します。大学では経営学を専攻し、ゼミ活動に力を入れてきました。本日はよろしくお願いいたします。"),
            entry("就職活動の軸", "私の就活の軸は三つあります。お客様に近いこと、現場の声を改善に返せること、仲間と成長できる文化があることです。"),
            entry("なぜ当社を志望するのか", "お客様がまだ言葉にできない迷いを、納得して選べる体験に変えたいからです。貴社の店舗ではそれが実現できると感じています。"),
            entry("自己PR", "私の強みは、相手の困りごとを聞き、条件を整理して動ける形にする力です。学生寮の代行サービスづくりでそれを発揮しました。"),
            entry("弱み・課題", "私の課題は慎重に考えすぎる点です。今は期限を決めて小さく動くことを意識しています。"),
            entry("研究テーマについて", "研究では、企業の情報開示と環境実績の関係を分析しています。数字だけでなく背景まで見る大切さを学びました。"),
            entry("全国転勤について", "関西に生活基盤がありますが、勤務地だけで判断するつもりはありません。配属先で早く信頼されることを大切にします。"),
            entry("第一志望ですか", "はい、第一志望として考えています。私の軸と一番重なるからです。"),
            entry("在留資格は大丈夫ですか", "はい、問題ございません。現在は留学の在留資格で、入社に合わせて就労可能な資格へ変更する予定です。"),
            entry("逆質問", "入社後、早く信頼されるために最初の半年で意識すべきことがあれば教えていただきたいです。"),
        ]
    }

    func testAnswerabilityCriterionMatchesParaphrasedQuestions() async throws {
        guard ProcessInfo.processInfo.environment["FI_ROUTER_PROBE"] == "1" else {
            throw XCTSkip("router probe disabled — set FI_ROUTER_PROBE=1 to run against the real network")
        }
        guard ProviderRegistry.llmResolution() != LLMResolution.none else {
            throw XCTSkip("no LLM key configured")
        }

        // 转述问法（一切都换了说法，语义可答）→ 期望 match 到对应条目。
        let answerable: [(q: String, gold: String)] = [
            ("それでは、簡単に自己紹介をお願いできますか。", "自己紹介"),
            ("就活ではどんな軸で企業を選んでいますか。", "就職活動の軸"),
            ("数ある企業の中で、どうしてうちなんですか。", "なぜ当社を志望するのか"),
            ("あなたの強みを教えてください。", "自己PR"),
            ("ご自身の弱みはどんなところだと思いますか。", "弱み・課題"),
            ("大学院ではどんな研究をされていますか。", "研究テーマについて"),
            ("勤務地が全国になる可能性がありますが、大丈夫ですか。", "全国転勤について"),
            ("うちは第一志望でしょうか。", "第一志望ですか"),
            ("ビザの手続きは問題ありませんか。", "在留資格は大丈夫ですか"),
            ("最後に、何か聞いておきたいことはありますか。", "逆質問"),
        ]
        // 稿子里不存在的问题 → 必须 null（读错稿比不读更糟）。
        let controls = [
            "昨日の日経平均株価についてどう思いますか。",
            "当社の新商品のマーケティング戦略を批判してください。",
        ]

        let router = LLMRouter()
        var hits = 0, wrong = 0
        for (q, gold) in answerable {
            let cands = QuestionMatcher.ranked(script, for: q, limit: 4)
            let d = try await router.route(question: q, candidates: cands)
            let goldAnswer = script.first { $0.question == gold }!.answer
            if d.matchedAnswer == goldAnswer { hits += 1 }
            else if d.matchedAnswer != nil { wrong += 1 }
            let matched = d.matchedAnswer.flatMap { a in script.first { $0.answer == a }?.question } ?? "null"
            NSLog("[router-probe] %@ → %@ (matched: %@)", q,
                  d.matchedAnswer == goldAnswer ? "HIT" : (d.matchedAnswer == nil ? "null" : "WRONG"),
                  matched)
        }
        var falsePositives = 0
        for q in controls {
            let cands = QuestionMatcher.ranked(script, for: q, limit: 4)
            let d = try await router.route(question: q, candidates: cands)
            if d.matchedAnswer != nil { falsePositives += 1 }
            NSLog("[router-probe] control %@ → %@", q, d.matchedAnswer == nil ? "null ✓" : "FALSE-POSITIVE")
        }

        NSLog("[router-probe] hit %d/%d, wrong %d, control false-positives %d/%d",
              hits, answerable.count, wrong, falsePositives, controls.count)
        XCTAssertGreaterThanOrEqual(hits, 6, "answerable paraphrases must mostly match (≥60%)")
        XCTAssertEqual(wrong, 0, "matching the WRONG entry is worse than a miss")
        XCTAssertEqual(falsePositives, 0, "conservativeness must survive: unknown questions → null")
    }

    /// 实机事故复现：ガクチカ回答后的深掘り「弊社ではどのように貢献できますか」。
    ///
    /// 修复前的双重失明：路由看不到上一轮对话，把追问当孤立问题；候选里靠「貢献」
    /// bigram 混入的「〜で貢献した経験」（过去经历）被误判命中——用户每次拿到的都是
    /// 答非所问的同一条原稿。可接受的判定只有两种：null（live 生成拿着 history 桥接）
    /// 或命中「なぜあなたを採用すべきですか」（语义上正面回答）。绝不能是经历条目。
    func testFollowUpContributionQuestionNeverMatchesPastExperience() async throws {
        guard ProcessInfo.processInfo.environment["FI_ROUTER_PROBE"] == "1" else {
            throw XCTSkip("router probe disabled — set FI_ROUTER_PROBE=1 to run against the real network")
        }
        guard ProviderRegistry.llmResolution() != LLMResolution.none else {
            throw XCTSkip("no LLM key configured")
        }

        let trap = entry("チーム以外の立場で貢献した経験はありますか",
                         "サークルの会計係として、備品管理の仕組みを作り直しました。目立たない役割でも改善を積み重ねる貢献が得意です。")
        let sellYourself = entry("採用人数を絞る中で、なぜあなたを採用すべきですか",
                                 "私を採用いただく理由は、課題を要件に落とす力と、現場に入り込む行動力です。貴社のプロジェクトで即戦力として貢献できます。")
        let gakuchika = entry("学生時代に力を入れたこと",
                              "学園祭の運営で、来場者データを分析して動線を改善しました。仮説を立てて検証する力が身につきました。")
        let script = [trap, gakuchika, sellYourself, entry("志望動機", "貴社の顧客起点の文化に共感したためです。")]

        let question = "弊社ではどのように貢献できますか？"
        let history = "面接官: 学生時代に頑張ったことは何ですか？\n回答案: \(gakuchika.answer)"

        let router = LLMRouter()
        var trapHits = 0
        let rounds = 3   // 小模型有随机性，跑三轮：一次都不允许命中陷阱
        for i in 0..<rounds {
            let cands = QuestionMatcher.ranked(script, for: question, limit: 4)
            let d = try await router.route(question: question, candidates: cands, history: history)
            let matched = d.matchedAnswer.flatMap { a in script.first { $0.answer == a }?.question } ?? "null"
            if d.matchedAnswer == trap.answer { trapHits += 1 }
            NSLog("[router-probe] follow-up round %d → %@", i + 1, matched)
        }
        XCTAssertEqual(trapHits, 0,
                       "深掘り貢献質問に過去経历稿を読ませてはならない（答非所问 × 每次一致）")
    }
}
