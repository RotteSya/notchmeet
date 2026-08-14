import XCTest
@testable import notchmeet

final class PortraitTests: XCTestCase {

    private func sheet() -> FactSheet {
        FactSheet(
            profile: "计算机专业应届生，强项是后端与数据。",
            experiences: [
                Experience(id: "campus", role: "学生", org: "某大学", period: "2021-2025",
                           actions: ["上课"], results: ["绩点 3.8"], skills: ["Java"], locked: true),
                Experience(id: "intern2", role: "后端实习", org: "星云数据", period: "2024.06-2024.09",
                           actions: ["把热点 Key 从 MySQL 迁到 Redis", "做了缓存穿透兜底"],
                           results: ["接口 P99 从 240ms 降到 40ms"], skills: ["Redis", "MySQL"], locked: true),
                Experience(id: "intern3", role: "前端实习", org: "画布科技", period: "2024.10-2025.01",
                           actions: ["改组件库"], results: ["构建时间减半"], skills: ["React"], locked: true),
                Experience(id: "proj4", role: "课程项目", org: "推荐系统课", period: "2023",
                           actions: ["写协同过滤"], results: ["离线 AUC 0.72"], skills: ["Python"], locked: true),
                Experience(id: "proj5", role: "志愿者", org: "支教团", period: "2022",
                           actions: ["带暑期课"], results: ["服务 80 人"], skills: ["沟通"], locked: true),
            ],
            motivations: [
                Motivation(id: "m1", targetCompany: "北极星",
                           statement: "想做低延迟基础设施。", careerAxis: "工程深度", locked: true),
            ],
            notes: ["期望薪资: 30万"]
        )
    }

    private func index(_ script: InterviewScript? = nil) -> PortraitIndex {
        let p = PortraitIndex()
        p.rebuild(sheet: sheet(), script: script, language: .chinese)
        return p
    }

    func testAskedProjectSurvivesAmongFiveExperiences() {
        let packed = index().pack(question: "第二个实习里 Redis 为什么那样选？", language: .chinese)
        XCTAssertTrue(packed.combined.contains("Redis"), "asked project missing: \(packed.combined)")
        XCTAssertTrue(packed.combined.contains("星云数据"))
        XCTAssertTrue(packed.identity.contains("北极星"), "identity/target company must always be present")
        // 无关的第五段不应把被问段挤掉（整表 dump 的典型失败）。
        XCTAssertTrue(packed.usedSlotIDs.contains("exp:intern2"))
    }

    func testPackedSlotsAreNeverMidTruncated() {
        let marker = "接口 P99 从 240ms 降到 40ms"
        let packed = index().pack(question: "Redis 缓存怎么做的？", language: .chinese)
        if packed.combined.contains("星云数据") {
            XCTAssertTrue(packed.combined.contains(marker), "experience slot was cut mid-render")
        }
        XCTAssertLessThanOrEqual(packed.factsBlock.count, PortraitIndex.factsBudget)
    }

    func testDeicticPinKeepsPreviousExperience() {
        let packed = index().pack(question: "刚才那个项目你遇到的最大困难是什么？",
                                  previousQuestion: "讲一下 Redis 缓存那次实习",
                                  pinnedIDs: ["exp:intern2"],
                                  language: .chinese)
        XCTAssertTrue(packed.usedSlotIDs.contains("exp:intern2"),
                      "deictic follow-up must pin the last experience, got \(packed.usedSlotIDs)")
        XCTAssertTrue(packed.combined.contains("星云数据"))
    }

    func testEmptyQuestionFillsInFileOrder() {
        let packed = index().pack(question: "", language: .chinese)
        XCTAssertTrue(packed.combined.contains("某大学"))
        XCTAssertTrue(packed.combined.contains("星云数据"))
        XCTAssertTrue(packed.identity.contains("计算机专业"))
    }

    func testRelevantScriptEntryIsIncluded() {
        let script = InterviewScript(name: "北极星", company: "北极星", entries: [
            BankEntry(id: "pad", intent: "爱好", question: "你有什么爱好",
                      answer: String(repeating: "我喜欢跑步。", count: 40), locked: true),
            BankEntry(id: "redis", intent: "项目", question: "Redis 缓存是怎么做的",
                      answer: "我把热点 Key 迁到 Redis，并加了空值兜底。", locked: true),
        ])
        let packed = index(script).pack(question: "缓存穿透你怎么防的？", language: .chinese)
        XCTAssertTrue(packed.scriptBlock.contains("我把热点 Key 迁到 Redis"),
                      "relevant script missing: \(packed.scriptBlock.prefix(200))")
        XCTAssertTrue(packed.scriptBlock.hasPrefix("# 用户准备的回答"))
    }

    func testChineseLabelsOnIdentityAndFacts() {
        let packed = index().pack(question: "自我介绍", language: .chinese)
        XCTAssertTrue(packed.identity.contains("个人简介") || packed.identity.contains("目标公司"))
        XCTAssertFalse(packed.combined.contains("プロフィール"))
    }
}

final class TurnSpeculationTests: XCTestCase {
    func testSameQuestionIsCovered() {
        let q = "请介绍一下你自己吗"
        XCTAssertTrue(TurnSpeculation.covers(spec: q, final: q, language: .chinese))
    }

    func testSpecAsPrefixOfMultiQuestionIsNotCovered() {
        let spec = "请介绍一下你自己吗"
        let final = "请介绍一下你自己吗 另外你的项目经历是什么"
        XCTAssertFalse(TurnSpeculation.covers(spec: spec, final: final, language: .chinese),
                       "Q1 must not cover Q1+Q2 — that skips the second question")
    }

    func testFinalPunctuationDropStillCovered() {
        XCTAssertTrue(TurnSpeculation.covers(spec: "请介绍一下你自己吗",
                                             final: "请介绍一下你自己",
                                             language: .chinese))
    }

    func testJapaneseContentRunsCover() {
        XCTAssertTrue(TurnSpeculation.covers(spec: "自己紹介をお願いしますか",
                                             final: "自己紹介をお願いします",
                                             language: .japanese))
        XCTAssertFalse(TurnSpeculation.covers(spec: "自己紹介をお願いします",
                                              final: "自己紹介をお願いします 志望動機も教えてください",
                                              language: .japanese))
    }
}
