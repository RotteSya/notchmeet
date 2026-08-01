import XCTest
@testable import notchmeet

/// 稿件的公司归属（审计 #20）——拿 A 公司的稿进 B 公司面试、把别家的志望動機逐字
/// 念出来，是这个 app 所有失败模式里最致命的一种，而此前一级自检里连当前用哪份稿
/// 都看不到（只藏在二级子菜单）。
final class ScriptCompanyTests: XCTestCase {
    private var dir: String!

    override func setUp() {
        super.setUp()
        dir = NSTemporaryDirectory() + "sc-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: dir)
        super.tearDown()
    }

    /// **迁移护栏**：加字段最容易踩的坑。Swift 合成的解码器对非 Optional 属性一律调
    /// `decode(_:forKey:)` 且不看属性默认值，缺键即抛错；而 `ScriptStore.reload` 一旦
    /// 解不开就会把 scripts.json 改名隔离、并从此拒绝一切写入——升级后用户看到的是
    /// 「稿件全空且存不进去」。所以 `company` 必须是 Optional。
    func testScriptsWrittenBeforeTheCompanyFieldStillLoad() throws {
        let legacy = """
        {"activeID":"s1","scripts":[{"id":"s1","name":"JINS 一次面接",
        "createdAt":760000000,"updatedAt":760000000,
        "entries":[{"id":"e1","intent":"自己紹介","question":"自己紹介","answer":"はい。","locked":true}]}]}
        """
        try legacy.write(toFile: dir + "/scripts.json", atomically: true, encoding: .utf8)

        let store = ScriptStore(directory: dir)

        XCTAssertEqual(store.loadState, .ok, "旧文件必须能解开——否则会被当成损坏隔离掉")
        XCTAssertEqual(store.all.count, 1)
        XCTAssertEqual(store.all.first?.name, "JINS 一次面接")
        XCTAssertNil(store.all.first?.company, "旧文件没有该字段 → nil，不是空字符串")
        XCTAssertEqual(store.activeID, "s1", "活动选择不能在升级中丢失")
    }

    /// 旧文件加载后仍然可写——隔离降级会让 save() 永久返回 false。
    func testLegacyLibraryRemainsWritable() throws {
        let legacy = """
        {"activeID":null,"scripts":[{"id":"s1","name":"旧稿","createdAt":760000000,
        "updatedAt":760000000,"entries":[]}]}
        """
        try legacy.write(toFile: dir + "/scripts.json", atomically: true, encoding: .utf8)

        let store = ScriptStore(directory: dir)
        XCTAssertNotNil(store.add(name: "新稿", company: "△△株式会社",
                                  entries: [BankEntry(id: "e", intent: "q", question: "q",
                                                      answer: "a", locked: true)]))
        XCTAssertEqual(ScriptStore(directory: dir).all.count, 2, "新增必须真的落盘")
    }

    func testCompanySurvivesRelaunchAndUpdate() {
        let store = ScriptStore(directory: dir)
        let entries = [BankEntry(id: "e", intent: "q", question: "q", answer: "a", locked: true)]
        let id = store.add(name: "一次面接", company: "△△株式会社", entries: entries)
        XCTAssertNotNil(id)

        XCTAssertEqual(ScriptStore(directory: dir).all.first?.company, "△△株式会社")

        XCTAssertTrue(store.update(id: id!, company: "□□株式会社"))
        XCTAssertEqual(ScriptStore(directory: dir).all.first?.company, "□□株式会社")
    }

    /// 空白公司名存成 nil，不留「有值但是空串」的半吊子状态（显示层会因此多出一对空括号）。
    func testBlankCompanyIsStoredAsNil() {
        let store = ScriptStore(directory: dir)
        let id = store.add(name: "稿", company: "   ", entries: [])
        XCTAssertNil(store.all.first(where: { $0.id == id })?.company)
    }

    /// 自检/菜单显示的那一行。
    func testDisplayLabelIncludesCompanyOnlyWhenPresent() {
        let withCompany = InterviewScript(name: "一次面接", company: "△△株式会社", entries: [])
        XCTAssertEqual(withCompany.displayLabel, "一次面接（△△株式会社）")

        let without = InterviewScript(name: "一次面接", entries: [])
        XCTAssertEqual(without.displayLabel, "一次面接")

        let blank = InterviewScript(name: "一次面接", company: "  ", entries: [])
        XCTAssertEqual(blank.displayLabel, "一次面接", "空白公司名不得渲染成空括号")
    }
}
