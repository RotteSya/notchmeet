import XCTest
@testable import notchmeet

/// F5: knowledge 文件的落盘位置。release .app 由 Finder/`open` 启动时 cwd = "/"，
/// 旧实现写 cwd/knowledge → 永远失败且静默，用户导入的面试稿一重启就消失。
final class KnowledgePathsTests: XCTestCase {
    func testEnvOverrideWins() {
        let dir = KnowledgePaths.resolve(env: ["FI_KNOWLEDGE_DIR": "/tmp/kn"],
                                         cwd: "/nonexistent", appSupport: "/apps")
        XCTAssertEqual(dir, "/tmp/kn")
    }

    func testUsesCwdKnowledgeWhenDirectoryExists() throws {
        let cwd = NSTemporaryDirectory() + "kp-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: cwd + "/knowledge",
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: cwd) }
        let dir = KnowledgePaths.resolve(env: [:], cwd: cwd, appSupport: "/apps",
                                         allowCwd: true)
        XCTAssertEqual(dir, cwd + "/knowledge")
    }

    func testFallsBackToAppSupportWhenCwdHasNoKnowledgeDir() {
        // release: cwd = "/"（/knowledge 不存在也不可写）→ 必须走 App Support
        let dir = KnowledgePaths.resolve(env: [:], cwd: "/", appSupport: "/apps",
                                         allowCwd: true)
        XCTAssertEqual(dir, "/apps/notchmeet")
    }

    /// release 构建必须无视 cwd/knowledge：Finder 启动时 cwd = "/"，若别的工具
    /// 在根目录建了 /knowledge，用户稿件会写进那里并与 App Support 的数据分裂。
    func testReleaseIgnoresCwdKnowledgeEvenIfItExists() throws {
        let cwd = NSTemporaryDirectory() + "kp-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: cwd + "/knowledge",
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: cwd) }
        let dir = KnowledgePaths.resolve(env: [:], cwd: cwd, appSupport: "/apps",
                                         allowCwd: false)
        XCTAssertEqual(dir, "/apps/notchmeet")
    }

    /// 环境覆盖优先级高于一切，QA/测试钩子在任何构建上都要可用。
    func testEnvOverrideWinsEvenWhenCwdDisallowed() {
        let dir = KnowledgePaths.resolve(env: ["FI_KNOWLEDGE_DIR": "/tmp/kn"],
                                         cwd: "/", appSupport: "/apps", allowCwd: false)
        XCTAssertEqual(dir, "/tmp/kn")
    }
}

final class ScriptStorePersistenceTests: XCTestCase {
    private var dir: String!

    override func setUp() {
        super.setUp()
        // 故意用一个还不存在的目录：save() 必须自己创建（App Support 首次运行同款路径）。
        dir = NSTemporaryDirectory() + "sp-\(UUID().uuidString)"
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: dir)
        super.tearDown()
    }

    private func entry(_ q: String) -> BankEntry {
        BankEntry(id: "e-\(q)", intent: q, question: q, answer: "\(q)の回答です。", locked: true)
    }

    func testScriptSurvivesRelaunch() {
        let store = ScriptStore(directory: dir)
        store.add(name: "JINS終面", entries: [entry("自己紹介"), entry("志望動機")])

        let relaunched = ScriptStore(directory: dir)
        XCTAssertEqual(relaunched.all.count, 1)
        XCTAssertEqual(relaunched.active?.name, "JINS終面")
        XCTAssertEqual(relaunched.active?.entries.map(\.question), ["自己紹介", "志望動機"])
    }

    func testActiveSelectionSurvivesRelaunch() {
        let store = ScriptStore(directory: dir)
        store.add(name: "A社", entries: [entry("自己紹介")])
        let bID = store.add(name: "B社", entries: [entry("志望動機")])
        store.setActive(bID)

        let relaunched = ScriptStore(directory: dir)
        XCTAssertEqual(relaunched.active?.name, "B社")
    }

    func testLegacySingleScriptFileMigratesWithinDirectory() throws {
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let legacy = [entry("自己紹介")]
        let data = try JSONEncoder().encode(legacy)
        try data.write(to: URL(fileURLWithPath: dir + "/script.json"))

        let store = ScriptStore(directory: dir)
        XCTAssertEqual(store.active?.entries.map(\.question), ["自己紹介"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir + "/script.json"),
                       "migrated legacy file should be removed")
    }
}

final class AnswerBankPersistenceTests: XCTestCase {
    /// `replaceAll` 是主线程隔离的（与 TurnManager 的读同域），测试也走主线程。
    @MainActor
    func testBankSurvivesRelaunch() {
        let dir = NSTemporaryDirectory() + "ab-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let bank = AnswerBank(directory: dir)
        bank.replaceAll([BankEntry(id: "b1", intent: "自己紹介", question: "自己紹介",
                                   answer: "回答です。", locked: false, format: .spoken)])

        let relaunched = AnswerBank(directory: dir)
        XCTAssertEqual(relaunched.entries.map(\.question), ["自己紹介"])
    }
}

final class LocalDataTests: XCTestCase {
    /// 「删除全部数据」必须覆盖每一个 Settings.apiKey 调用点用到的 key —— 旧实现漏了
    /// DeepSeek/DashScope，隐私清除后域内 LLM key 仍留在 Keychain。
    func testManagedSecretKeysCoverEveryProviderKey() {
        for key in ["DEEPGRAM_API_KEY", "GEMINI_API_KEY", "ANTHROPIC_API_KEY",
                    "DEEPSEEK_API_KEY", "DASHSCOPE_API_KEY"] {
            XCTAssertTrue(LocalData.managedSecretKeys.contains(key), "missing \(key)")
        }
    }
}
