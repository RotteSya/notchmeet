import XCTest
@testable import notchmeet

/// 简历事实的写入口（审计 #18）。此前 `FactSheet` 有模型、有读取器、有三处消费者，
/// 却没有任何 writer——普通用户的事实上下文恒为空，于是数字类问题只能答空话。
/// 这组测试守住：文本约定解析正确、能落盘、落盘后 grounding 真的拿得到。
final class FactsEditorTests: XCTestCase {
    private var dir: String!

    override func setUp() {
        super.setUp()
        dir = NSTemporaryDirectory() + "facts-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        setenv("FI_FACTS", dir + "/facts.json", 1)
    }

    override func tearDown() {
        unsetenv("FI_FACTS")
        try? FileManager.default.removeItem(atPath: dir)
        super.tearDown()
    }

    // MARK: - 解析

    func testParsesExperienceWithAllFields() {
        let sheet = FactsTextFormat.parse("""
            # 経験: □□株式会社でのインターン
            役割: 運営チームリーダー
            期間: 2024.07-2024.09
            行動: 5名のチームをまとめた
            行動: 手順を再設計した
            成果: 待ち時間を20%短縮
            スキル: 多国籍チーム運営 / 調整力
            """)

        XCTAssertEqual(sheet.experiences.count, 1)
        let e = try! XCTUnwrap(sheet.experiences.first)
        XCTAssertEqual(e.org, "□□株式会社でのインターン")
        XCTAssertEqual(e.role, "運営チームリーダー")
        XCTAssertEqual(e.period, "2024.07-2024.09")
        XCTAssertEqual(e.actions, ["5名のチームをまとめた", "手順を再設計した"], "同じラベルは積み上がる")
        XCTAssertEqual(e.results, ["待ち時間を20%短縮"])
        XCTAssertEqual(e.skills, ["多国籍チーム運営", "調整力"], "スキルだけは区切り文字で分割する")
    }

    /// 数字类速答的素材（希望年収 / 入社可能時期 / TOEIC）走 notes——这是这一页存在的主要理由。
    func testNotesCarryTheHardNumbers() {
        let sheet = FactsTextFormat.parse("""
            # メモ
            希望年収: 400万円
            入社可能時期: 2026年4月
            - TOEIC: 850点
            """)
        XCTAssertEqual(sheet.notes, ["希望年収: 400万円", "入社可能時期: 2026年4月", "TOEIC: 850点"],
                       "行頭の記号は剥がすが、中身の「ラベル: 値」はそのまま残す")
    }

    func testMotivationCarriesCompanyAndAxis() {
        let sheet = FactsTextFormat.parse("""
            # 志望: JINS
            軸: ものづくりと接客の両立
            理由: 貴社の姿勢に共感しました。
            """)
        let m = try! XCTUnwrap(sheet.motivations.first)
        XCTAssertEqual(m.targetCompany, "JINS")
        XCTAssertEqual(m.careerAxis, "ものづくりと接客の両立")
        XCTAssertEqual(m.statement, "貴社の姿勢に共感しました。")
    }

    /// 界面有中日两种语言，标签也必须两种都认——否则中文用户写的表被静默丢弃。
    func testAcceptsChineseLabelsAndFullWidthColon() {
        let sheet = FactsTextFormat.parse("""
            # 经历: 某某公司
            角色：运营负责人
            期间：2023-2024
            成果：转化率提升 15%
            技能：数据分析、项目管理
            """)
        let e = try! XCTUnwrap(sheet.experiences.first)
        XCTAssertEqual(e.role, "运营负责人")
        XCTAssertEqual(e.period, "2023-2024")
        XCTAssertEqual(e.results, ["转化率提升 15%"])
        XCTAssertEqual(e.skills, ["数据分析", "项目管理"])
    }

    /// 直接粘一段自我介绍（没有任何标题）不能全部丢掉——当作简介收下。
    func testTextBeforeAnyHeadingBecomesProfile() {
        let sheet = FactsTextFormat.parse("△△大学大学院で経営学を専攻しています。")
        XCTAssertEqual(sheet.profile, "△△大学大学院で経営学を専攻しています。")
        XCTAssertTrue(sheet.experiences.isEmpty)
    }

    /// 经历块里没打标签的行不丢弃（大多数人直接写做过什么）。
    func testUnlabeledLineInsideExperienceIsKeptAsAction() {
        let sheet = FactsTextFormat.parse("""
            # 経験: ゼミ
            チームで共同研究を進めました
            """)
        XCTAssertEqual(sheet.experiences.first?.actions, ["チームで共同研究を進めました"])
    }

    func testEmptyTextParsesToEmptySheet() {
        let sheet = FactsTextFormat.parse("   \n\n  ")
        XCTAssertTrue(FactsTextFormat.isEmptySheetText(sheet))
    }

    // MARK: - 回写

    /// 编辑器保存后会把规范形回填——回写必须能被自己重新解析成同一份事实。
    func testRoundTripThroughCanonicalText() {
        let original = FactsTextFormat.parse(FactsTextFormat.sample)
        let reparsed = FactsTextFormat.parse(FactsTextFormat.text(for: original))

        XCTAssertEqual(reparsed.profile, original.profile)
        XCTAssertEqual(reparsed.experiences.count, original.experiences.count)
        XCTAssertEqual(reparsed.experiences.first?.org, original.experiences.first?.org)
        XCTAssertEqual(reparsed.experiences.first?.actions, original.experiences.first?.actions)
        XCTAssertEqual(reparsed.experiences.first?.skills, original.experiences.first?.skills)
        XCTAssertEqual(reparsed.motivations.first?.targetCompany, original.motivations.first?.targetCompany)
        XCTAssertEqual(reparsed.motivations.first?.careerAxis, original.motivations.first?.careerAxis)
        XCTAssertEqual(reparsed.notes, original.notes)
    }

    /// 内置示例必须真的解析得出东西——它是用户学格式的唯一入口。
    func testBundledSampleParsesIntoUsableFacts() {
        let sheet = FactsTextFormat.parse(FactsTextFormat.sample)
        XCTAssertNotNil(sheet.profile)
        XCTAssertFalse(sheet.experiences.isEmpty)
        XCTAssertFalse(sheet.motivations.isEmpty)
        XCTAssertFalse(sheet.notes.isEmpty, "示例必须包含数字类备忘——那正是这一页要解决的问题")
    }

    // MARK: - 落盘

    func testSavePersistsAndReloads() {
        let store = FactStore()
        let sheet = FactsTextFormat.parse("""
            # メモ
            希望年収: 400万円
            """)
        XCTAssertTrue(store.save(sheet))

        let reloaded = FactStore()          // 新实例 = 模拟重启
        XCTAssertEqual(reloaded.sheet.notes, ["希望年収: 400万円"])
    }

    /// 个人信息文件必须只有本用户可读（同 scripts.json 的约定）。
    func testSavedFileIsOwnerReadableOnly() throws {
        let store = FactStore()
        XCTAssertTrue(store.save(FactsTextFormat.parse("# メモ\nTOEIC: 850")))

        let attrs = try FileManager.default.attributesOfItem(atPath: store.writePath)
        XCTAssertEqual(attrs[.posixPermissions] as? NSNumber, 0o600)
    }

    /// 端到端的重点：存下去之后，喂给 LLM 的 grounding 里真的出现了这些数字。
    /// 这一步不通，这一页就只是个漂亮的文本框。
    func testSavedFactsReachTheGeneratorContext() {
        let store = FactStore()
        XCTAssertTrue(store.save(FactsTextFormat.parse("""
            # メモ
            希望年収: 400万円
            入社可能時期: 2026年4月
            """)))

        let context = FactStore().context(for: "希望年収はどのくらいですか")
        XCTAssertTrue(context.contains("400万円"), "存下的事实必须进入生成上下文")
        XCTAssertTrue(context.contains("2026年4月"))
    }

    func testSaveFailureIsReportedNotSwallowed() {
        setenv("FI_FACTS", "/nonexistent-root-\(UUID().uuidString)/facts.json", 1)
        let store = FactStore()
        XCTAssertFalse(store.save(FactsTextFormat.parse("# メモ\nA: B")),
                       "写不进去必须如实返回 false —— 静默成功 = 用户以为填好了，面试当天是空的")
    }
}

/// 简历事实一旦有了写入口，「预生成回答」那条路径的隐私门就从「反正事实是空的」
/// 变成一条真实的泄漏路径。这条测试守住它与实时生成用的是同一道门。
final class PreGeneratorPrivacyGateTests: XCTestCase {
    private var dir: String!
    private var original: Bool!

    override func setUp() {
        super.setUp()
        dir = NSTemporaryDirectory() + "facts-gate-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        setenv("FI_FACTS", dir + "/facts.json", 1)
        original = Settings.sendContextToLLM
    }

    override func tearDown() {
        Settings.sendContextToLLM = original
        unsetenv("FI_FACTS")
        try? FileManager.default.removeItem(atPath: dir)
        super.tearDown()
    }

    func testResumeFactsAreWithheldWhenTheUserOptedOut() {
        let store = FactStore()
        XCTAssertTrue(store.save(FactsTextFormat.parse("# メモ\n希望年収: 400万円")))

        Settings.sendContextToLLM = true
        XCTAssertTrue(PreGenerator.groundingContext(FactStore()).contains("400万円"))

        Settings.sendContextToLLM = false
        XCTAssertTrue(PreGenerator.groundingContext(FactStore()).isEmpty,
                      "关掉「把简历发给 AI」后，预生成也不得把简历送出去")
    }
}
