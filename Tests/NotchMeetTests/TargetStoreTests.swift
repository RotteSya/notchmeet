import XCTest
@testable import notchmeet

final class TargetStorePersistenceTests: XCTestCase {
    private var dir: String!

    override func setUp() {
        super.setUp()
        // 故意用一个还不存在的目录：save() 必须自己创建（App Support 首次运行同款路径）。
        dir = NSTemporaryDirectory() + "tg-\(UUID().uuidString)"
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: dir)
        super.tearDown()
    }

    func testTargetSurvivesRelaunch() {
        let store = TargetStore(directory: dir)
        store.add(company: "北极星", role: "后端开发", stage: "一面")

        let relaunched = TargetStore(directory: dir)
        XCTAssertEqual(relaunched.all.count, 1)
        XCTAssertEqual(relaunched.active?.company, "北极星")
        XCTAssertEqual(relaunched.active?.role, "后端开发")
        XCTAssertEqual(relaunched.active?.displayLabel, "北极星 · 后端开发")
    }

    func testEmptyCompanyIsRejected() {
        let store = TargetStore(directory: dir)
        XCTAssertNil(store.add(company: "   "))
        XCTAssertTrue(store.all.isEmpty)
    }

    func testActiveSelectionSurvivesRelaunch() {
        let store = TargetStore(directory: dir)
        store.add(company: "A社")
        let bID = store.add(company: "B社")
        store.setActive(bID)

        let relaunched = TargetStore(directory: dir)
        XCTAssertEqual(relaunched.active?.company, "B社")
    }

    func testRemovingActiveTargetFallsBackToNone() {
        let store = TargetStore(directory: dir)
        let aID = store.add(company: "A社")
        store.add(company: "B社")
        store.remove(id: aID!)
        // 绝不静默替用户选一个没选过的目标。
        XCTAssertNil(store.active)
        XCTAssertEqual(store.all.count, 1)
    }

    /// `.some(nil)` 清空字段、外层 nil 不动字段——双层 Optional 的更新约定。
    func testUpdateDistinguishesClearFromUntouched() {
        let store = TargetStore(directory: dir)
        let id = store.add(company: "A社", role: "算法", stage: "一面")!
        store.update(id: id, stage: .some("终面"))
        XCTAssertEqual(store.active?.role, "算法", "未提及的字段不得被动")
        XCTAssertEqual(store.active?.stage, "终面")
        store.update(id: id, role: .some(nil))
        XCTAssertNil(store.active?.role, ".some(nil) 必须清空字段")
    }

    /// 损坏文件：隔离原件 + 只读降级拒写（同 ScriptStore 的数据保护纪律）。
    func testCorruptLibraryIsQuarantinedAndSaveRefused() throws {
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try "not json{{{".write(toFile: dir + "/targets.json", atomically: true, encoding: .utf8)

        let store = TargetStore(directory: dir)
        guard case .corrupt(let quarantined) = store.loadState else {
            return XCTFail("corrupt file must enter read-only degradation, got \(store.loadState)")
        }
        XCTAssertNotNil(quarantined)
        XCTAssertTrue(FileManager.default.fileExists(atPath: quarantined!),
                      "original bytes must survive for manual recovery")
        XCTAssertNil(store.add(company: "新目标"), "corrupt state must refuse writes")
        XCTAssertTrue(store.lastSaveFailed)
    }
}

final class TargetSeedingTests: XCTestCase {
    private var dir: String!

    override func setUp() {
        super.setUp()
        dir = NSTemporaryDirectory() + "ts-\(UUID().uuidString)"
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: dir)
        super.tearDown()
    }

    private func script(_ name: String, company: String?, id: String) -> InterviewScript {
        InterviewScript(id: id, name: name, company: company,
                        entries: [BankEntry(id: "e", intent: "自己紹介",
                                            question: "自己紹介", answer: "回答", locked: true)])
    }

    func testSeedsFromScriptCompaniesAndMotivations() {
        let store = TargetStore(directory: dir)
        let ok = store.seedIfNeeded(
            scripts: [script("终面稿", company: "北极星", id: "s1"),
                      script("一面稿", company: "北极星", id: "s2"),   // 同公司去重
                      // company 空、名字又提取不出公司（纯日期）→ 跳过
                      script("2026-07-30", company: nil, id: "s3")],
            activeScriptID: "s1",
            motivations: [Motivation(id: "m1", targetCompany: "画布科技",
                                     statement: "想做工具", careerAxis: nil, locked: true),
                          Motivation(id: "m2", targetCompany: "北极星",   // 与稿件公司去重
                                     statement: "想做基建", careerAxis: nil, locked: true)])
        XCTAssertTrue(ok)
        XCTAssertEqual(store.all.map(\.company).sorted(), ["北极星", "画布科技"])
        // 活跃稿的公司成为活跃目标，并保留稿件绑定。
        XCTAssertEqual(store.active?.company, "北极星")
        XCTAssertEqual(store.active?.scriptID, "s1")
    }

    /// 文件一旦存在（哪怕目标被用户删光）绝不重播——删掉的目标不得复活。
    func testSeedingNeverRunsTwice() {
        let store = TargetStore(directory: dir)
        store.seedIfNeeded(scripts: [script("稿", company: "北极星", id: "s1")],
                           activeScriptID: "s1", motivations: [])
        store.remove(id: store.all[0].id)
        XCTAssertTrue(store.all.isEmpty)

        let relaunched = TargetStore(directory: dir)
        let reseeded = relaunched.seedIfNeeded(
            scripts: [script("稿", company: "北极星", id: "s1")],
            activeScriptID: "s1", motivations: [])
        XCTAssertFalse(reseeded)
        XCTAssertTrue(relaunched.all.isEmpty, "user-deleted targets must not resurrect")
    }

    /// 存量稿件的 company 字段普遍为空（那是后加的字段），但稿件名就是公司名。
    /// 这是真实用户数据的形态——不兜底的话升级后工作台首屏全空。
    func testSeedsCompanyFromScriptNameWhenFieldIsEmpty() {
        let store = TargetStore(directory: dir)
        let ok = store.seedIfNeeded(
            scripts: [script("コグニザントジャパン_interview_integrated_2026-07-26", company: nil, id: "s1"),
                      script("テクノプロ・IT社", company: nil, id: "s2"),
                      script("テクノプロ・IT社_interview_integrated_2026-07-28", company: nil, id: "s3")],
            activeScriptID: "s2", motivations: [])
        XCTAssertTrue(ok)
        // 同公司的两份稿去重成一个目标。
        XCTAssertEqual(store.all.map(\.company).sorted(),
                       ["コグニザントジャパン", "テクノプロ・IT社"])
        XCTAssertEqual(store.active?.company, "テクノプロ・IT社")
        XCTAssertEqual(store.active?.scriptID, "s2")
    }

    /// 播错公司名会污染热词表与画像 identity——从严：可疑名字宁可不播。
    func testScriptNameExtractionRejectsSuspiciousNames() {
        XCTAssertEqual(TargetStore.companyFromScriptName("船井総合研究所_interview_integrated_2026-07-30"),
                       "船井総合研究所")
        XCTAssertEqual(TargetStore.companyFromScriptName("エスユーエス"), "エスユーエス")
        XCTAssertNil(TargetStore.companyFromScriptName("2026-07-30_interview"))
        XCTAssertNil(TargetStore.companyFromScriptName("interview_integrated_2026"))
        XCTAssertNil(TargetStore.companyFromScriptName("面接原稿"))
        XCTAssertNil(TargetStore.companyFromScriptName("A"))
    }

    /// 无可播种数据时不落盘：下次启动仍可再试（无害幂等），且不产生空文件挡路。
    func testEmptySeedWritesNothing() {
        let store = TargetStore(directory: dir)
        let ok = store.seedIfNeeded(scripts: [script("稿", company: nil, id: "s1")],
                                    activeScriptID: nil, motivations: [])
        XCTAssertFalse(ok)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir + "/targets.json"))
        if case .empty = store.loadState {} else { XCTFail("must stay .empty for a later retry") }
    }

    /// 存量 targets.json 缺新字段也要能解开（Optional 红线的回归防线）。
    func testDecodesFileWithMissingOptionalFields() throws {
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let minimal = """
        {"targets":[{"id":"t1","company":"北极星",
        "createdAt":700000000,"updatedAt":700000000}]}
        """
        try minimal.write(toFile: dir + "/targets.json", atomically: true, encoding: .utf8)
        let store = TargetStore(directory: dir)
        XCTAssertEqual(store.all.count, 1, "missing optional keys must not read as corrupt")
        XCTAssertEqual(store.all[0].company, "北极星")
        XCTAssertNil(store.all[0].role)
    }
}

/// 答案库按目标分文件：隔离、只读回落、重启保持。
final class AnswerBankTargetTests: XCTestCase {
    private func entry(_ id: String) -> BankEntry {
        BankEntry(id: id, intent: "志望動機", question: "志望動機",
                  answer: "\(id) の回答", locked: false, format: .spoken)
    }

    @MainActor
    func testPerTargetBankIsolatesAndFallsBackToLegacy() {
        let dir = NSTemporaryDirectory() + "bk-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let bank = AnswerBank(directory: dir)
        bank.replaceAll([entry("global")])

        // 目标自己的库还没建 → 只读回落到全局库（存量用户武装目标不至于库瞬间清零）。
        bank.activate(targetID: "t1")
        XCTAssertEqual(bank.entries.map(\.id), ["global"])

        // 保存永远写进目标自己的文件，绝不覆盖全局库。
        bank.replaceAll([entry("t1-answer")])
        bank.activate(targetID: nil)
        XCTAssertEqual(bank.entries.map(\.id), ["global"], "target save must not touch the legacy bank")
        bank.activate(targetID: "t1")
        XCTAssertEqual(bank.entries.map(\.id), ["t1-answer"])

        let relaunched = AnswerBank(directory: dir, targetID: "t1")
        XCTAssertEqual(relaunched.entries.map(\.id), ["t1-answer"])
    }
}

/// 一司一策在画像层的三个承诺：identity 只报本场目标、排除项检索不可见、置顶项必在视野。
final class PortraitTargetTests: XCTestCase {
    private func sheet() -> FactSheet {
        FactSheet(
            profile: "计算机专业应届生。",
            experiences: [
                Experience(id: "redis", role: "后端实习", org: "星云数据", period: "2024",
                           actions: ["热点迁 Redis"], results: ["P99 降到 40ms"],
                           skills: ["Redis"], locked: true),
                Experience(id: "rival", role: "增长实习", org: "竞对公司", period: "2023",
                           actions: ["投放"], results: ["ROI 1.8"], skills: ["投放"], locked: true),
                Experience(id: "volunteer", role: "志愿者", org: "支教团", period: "2022",
                           actions: ["带课"], results: ["服务 80 人"], skills: ["沟通"], locked: true),
            ],
            motivations: [
                Motivation(id: "m1", targetCompany: "北极星",
                           statement: "想做低延迟基础设施。", careerAxis: "工程深度", locked: true),
                Motivation(id: "m2", targetCompany: "画布科技",
                           statement: "想做创作工具。", careerAxis: nil, locked: true),
            ],
            notes: [])
    }

    private func target(emphasis: TargetEmphasis? = nil) -> InterviewTarget {
        InterviewTarget(company: "北极星", role: "后端开发", emphasis: emphasis)
    }

    func testIdentityReportsOnlyArmedTarget() {
        let p = PortraitIndex()
        p.rebuild(sheet: sheet(), script: nil, target: target(), language: .chinese)
        let packed = p.pack(question: "自我介绍", language: .chinese)
        XCTAssertTrue(packed.identity.contains("北极星"))
        XCTAssertTrue(packed.identity.contains("后端开发"))
        // 别家志望公司绝不进 identity——拿 A 家志望进 B 家面试是最致命的失败模式。
        XCTAssertFalse(packed.identity.contains("画布科技"),
                       "identity leaked another company's motivation: \(packed.identity)")
    }

    func testNilTargetKeepsLegacyAggregation() {
        let p = PortraitIndex()
        p.rebuild(sheet: sheet(), script: nil, language: .chinese)
        let packed = p.pack(question: "自我介绍", language: .chinese)
        XCTAssertTrue(packed.identity.contains("北极星"))
        XCTAssertTrue(packed.identity.contains("画布科技"))
    }

    func testExcludedFactIsInvisibleEvenWhenAsked() {
        let p = PortraitIndex()
        p.rebuild(sheet: sheet(), script: nil,
                  target: target(emphasis: TargetEmphasis(pinnedFactIDs: nil,
                                                          excludedFactIDs: ["rival"],
                                                          keywords: nil, note: nil)),
                  language: .chinese)
        let packed = p.pack(question: "你做过投放吗？竞对公司那段实习讲讲", language: .chinese)
        XCTAssertFalse(packed.combined.contains("竞对公司"),
                       "excluded fact must be unreachable: \(packed.combined)")
        XCTAssertFalse(packed.usedSlotIDs.contains("exp:rival"))
    }

    func testPinnedFactStaysInViewOnUnrelatedQuestion() {
        let p = PortraitIndex()
        p.rebuild(sheet: sheet(), script: nil,
                  target: target(emphasis: TargetEmphasis(pinnedFactIDs: ["redis"],
                                                          excludedFactIDs: nil,
                                                          keywords: nil, note: nil)),
                  language: .chinese)
        // 问题与置顶经历毫无词面交集，置顶仍须在视野内。
        let packed = p.pack(question: "你的兴趣爱好是什么？", language: .chinese)
        XCTAssertTrue(packed.usedSlotIDs.contains("exp:redis"),
                      "emphasis-pinned fact fell out of view: \(packed.usedSlotIDs)")
    }
}
