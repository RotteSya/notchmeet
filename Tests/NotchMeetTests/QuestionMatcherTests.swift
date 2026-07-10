import XCTest
@testable import notchmeet

final class QuestionMatcherTests: XCTestCase {
    private func entry(_ question: String) -> BankEntry {
        BankEntry(id: question, intent: question, question: question, answer: question, locked: true)
    }

    func testCanonicalTopicOutranksUnrelatedLongQuestions() {
        let entries = [
            entry("学生時代にチームで努力した経験を教えてください"),
            entry("最近関心を持った課題について教えてください"),
            entry("自己紹介"),
            entry("志望動機"),
            entry("キャリアプラン"),
        ]

        let result = QuestionMatcher.ranked(entries, for: "当社への志望動機を教えてください。", limit: 2)
        XCTAssertEqual(result.first?.question, "志望動機")
    }

    func testAliasRecognitionRanksGakuchikaFirst() {
        let entries = [entry("自己PR"), entry("逆質問"), entry("ガクチカ"), entry("弱み")]
        let result = QuestionMatcher.ranked(entries,
                                            for: "学生時代に最も力を入れたことをお聞かせください。",
                                            limit: 1)
        XCTAssertEqual(result.first?.question, "ガクチカ")
    }

    func testStrengthAndWeaknessBothRemainTopCandidates() {
        let entries = [entry("志望動機"), entry("強み"), entry("研究内容"), entry("弱み"), entry("逆質問")]
        let result = QuestionMatcher.ranked(entries, for: "あなたの強みと弱みを教えてください。", limit: 2)
        XCTAssertEqual(Set(result.map(\.question)), Set(["強み", "弱み"]))
    }

    /// JINS 稿实测唯一预筛 miss：话题式标题「自己PR」与口头问法「あなたの強みは？」
    /// 零字面重叠，必须靠 strength 话题别名桥接。
    func testJikoPRRanksTopForStrengthQuestion() {
        let entries = [
            entry("あなた自身の役割は何でしたか"), entry("一番難しかったことは何ですか"),
            entry("なぜ日本語を勉強したのですか"), entry("第一志望ですか"),
            entry("自己PR"),
        ]
        let result = QuestionMatcher.ranked(entries, for: "あなたの強みは何ですか。", limit: 4)
        XCTAssertTrue(result.map(\.question).contains("自己PR"),
                      "自己PR must reach the router's top-4 for a 強み question")
    }

    /// 真实路由探针暴露的三个预筛缺口：词汇鸿沟导致 gold 条目进不了 top-4，
    /// router 根本没机会判断（prompt 写了同义词规则也救不回来）。
    func testVocabularyGapsBridgedByTopicAliases() {
        let entries = [
            entry("自己紹介"), entry("就職活動の軸"), entry("なぜ当社を志望するのか"),
            entry("自己PR"), entry("弱み・課題"), entry("研究テーマについて教えてください"),
            entry("全国転勤について"), entry("第一志望ですか"),
            entry("在留資格は大丈夫ですか"), entry("逆質問"),
            // 真实稿里挤掉 gold 的竞争条目（bigram されていますか/どんな 撞车）。
            entry("MBAでは何を学んでいますか"), entry("他にどんな業界を受けていますか"),
            entry("なぜ中国ではなく、日本で大学院に進学したのですか"), entry("どんなSDになりたいか"),
        ]
        let cases: [(q: String, gold: String)] = [
            ("ビザの手続きは問題ありませんか。", "在留資格は大丈夫ですか"),
            ("最後に、何か聞いておきたいことはありますか。", "逆質問"),
            ("数ある企業の中で、どうしてうちなんですか。", "なぜ当社を志望するのか"),
            ("大学院ではどんな研究をされていますか。", "研究テーマについて教えてください"),
        ]
        for (q, gold) in cases {
            let top = QuestionMatcher.ranked(entries, for: q, limit: 4).map(\.question)
            XCTAssertTrue(top.contains(gold), "\(q) → top4 \(top) missing \(gold)")
        }
    }

    func testTieKeepsUserAuthoredOrder() {
        let entries = [entry("趣味"), entry("特技"), entry("アルバイト")]
        let result = QuestionMatcher.ranked(entries, for: "休日", limit: 2)
        XCTAssertEqual(result.map(\.question), ["趣味", "特技"])
    }
}
