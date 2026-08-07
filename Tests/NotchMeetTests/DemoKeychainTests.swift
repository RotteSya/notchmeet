import XCTest
@testable import notchmeet

/// demo 管线（FI_UI_DEMO 视觉 QA）不得触碰 Keychain。
///
/// 2026-08-07 实测：DEBUG 构建带 FI_UI_DEMO=1 启动仍弹 com.notchmeet.keys 的
/// ACL 密码框——`AppController.start()` 里的受管迁移/迎新赠礼/额度账本载入都在
/// 进入 pipeline 分支**之前**就读了 Keychain，不受 FI_UI_DEMO 约束。
///
/// 修法是把全部 Keychain 触点（`Secrets`、`KeychainCreditStore` 账本、启动期
/// 计费初始化）统一挂在 `AppConfig.keychainAllowed` 这一道门后。仓库里 SecItem
/// 调用只存在于 Secrets.swift 与 CreditLedger.swift 两个文件，所以这组测试
/// 一半验门本身的判定（纯函数），一半扫源码验每个触点确实在门后——单点修好
/// 再被第四处启动代码绕过，正是这次的成因。
final class DemoKeychainTests: XCTestCase {

    // MARK: - 门的判定（纯函数）

    func testUIDemoEnvResolvesToDemoPipeline() {
        XCTAssertEqual(AppConfig.pipeline(environment: ["FI_UI_DEMO": "1"], arguments: []), .demo)
        XCTAssertEqual(AppConfig.pipeline(environment: [:], arguments: ["--ui-demo"]), .demo)
    }

    func testDemoPipelineBlocksKeychain() {
        XCTAssertFalse(AppConfig.keychainAllowed(for: .demo),
                       "demo 管线必须承诺零 Keychain 访问")
        XCTAssertTrue(AppConfig.keychainAllowed(for: .auto))
        XCTAssertTrue(AppConfig.keychainAllowed(for: .live))
        XCTAssertTrue(AppConfig.keychainAllowed(for: .mock))
    }

    /// FI_UI_DEMO 压过 FI_PIPELINE：两者同设时仍是 demo（仍零 Keychain）。
    func testUIDemoWinsOverForcedPipeline() {
        XCTAssertEqual(AppConfig.pipeline(environment: ["FI_UI_DEMO": "1",
                                                        "FI_PIPELINE": "live"],
                                          arguments: []), .demo)
    }

    /// 测试进程自身没开 demo（否则下面的源码扫描在骗人——门在本进程恒关）。
    func testGateIsOffInTestProcess() {
        XCTAssertNil(ProcessInfo.processInfo.environment["FI_UI_DEMO"],
                     "本测试假设 FI_UI_DEMO 未设置")
    }

    // MARK: - 源码扫描：每个 Keychain 触点都必须在门后

    private func source(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/NotchMeetTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    /// Secrets.get：门必须先于 SecItemCopyMatching。
    func testSecretsReadIsGated() throws {
        let text = try source("Sources/NotchMeet/Core/Secrets.swift")
        let gate = text.range(of: "guard AppConfig.keychainAllowed")
        let read = text.range(of: "SecItemCopyMatching")
        XCTAssertNotNil(gate, "Secrets.get 丢失了 AppConfig.keychainAllowed 门")
        XCTAssertNotNil(read)
        if let gate, let read {
            XCTAssertLessThan(gate.lowerBound, read.lowerBound,
                              "Secrets 的门必须挡在 SecItemCopyMatching 之前")
        }
    }

    /// CreditManager.shared：demo 分支（内存账本）必须先于 Keychain 账本的默认分支。
    func testCreditLedgerFactoryIsGated() throws {
        let text = try source("Sources/NotchMeet/Core/Credit/CreditManager.swift")
        let gate = text.range(of: "!AppConfig.keychainAllowed")
        let fallback = text.range(of: "return CreditManager()")
        XCTAssertNotNil(gate, "CreditManager.shared 丢失了 demo 内存账本分支")
        XCTAssertNotNil(fallback)
        if let gate, let fallback {
            XCTAssertLessThan(gate.lowerBound, fallback.lowerBound,
                              "demo 分支必须挡在 Keychain 账本默认分支之前")
        }
    }

    /// AppController：启动期计费初始化只能出现在 bootstrapCreditIfAllowed 的
    /// guard 之后——三条调用任何一条挪回 start()（或新增第二处调用），
    /// 就回到了「进 pipeline 分支之前先读 Keychain」的老病。
    func testStartupCreditCallsSitBehindTheGate() throws {
        let lines = try source("Sources/NotchMeet/App/AppController.swift")
            .components(separatedBy: "\n")
        guard let gateLine = lines.firstIndex(where: {
            $0.contains("guard AppConfig.keychainAllowed")
        }) else {
            return XCTFail("AppController 丢失了 bootstrapCreditIfAllowed 的门")
        }
        // 门之后、下一个函数声明之前，就是允许触碰 Keychain 的唯一区间。
        let nextFunc = lines[(gateLine + 1)...].firstIndex { $0.contains("func ") }
            ?? lines.count
        for marker in ["ManagedKeyRegistry.migrateLegacyFlagsIfNeeded()",
                       "credit.bootstrap()"] {
            let hits = lines.indices.filter { lines[$0].contains(marker) }
            XCTAssertEqual(hits.count, 1, "\(marker) 只允许一个调用点（门后）")
            for i in hits {
                XCTAssertTrue(i > gateLine && i < nextFunc,
                              "AppController.swift:\(i + 1) \(marker) 出现在门外")
            }
        }
        // observeCredit 另有函数声明行，只查调用点。
        let observeCalls = lines.indices.filter {
            lines[$0].contains("observeCredit()") && !lines[$0].contains("func ")
        }
        XCTAssertEqual(observeCalls.count, 1, "observeCredit() 只允许一个调用点（门后）")
        for i in observeCalls {
            XCTAssertTrue(i > gateLine && i < nextFunc,
                          "AppController.swift:\(i + 1) observeCredit() 出现在门外")
        }
    }

    /// SecItem 触点不得扩散：新增第三个直接调 SecItem* 的文件必须同样挂门，
    /// 并把它加进这份清单。
    func testSecItemCallersStayEnumerated() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let allowed: Set<String> = ["Secrets.swift", "CreditLedger.swift"]
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" } ?? []
        XCTAssertFalse(files.isEmpty)
        for url in files where !allowed.contains(url.lastPathComponent) {
            let text = try String(contentsOf: url, encoding: .utf8)
            XCTAssertFalse(text.contains("SecItem"),
                           "\(url.lastPathComponent) 直接调用了 SecItem*——Keychain 访问必须收敛在 \(allowed.sorted()) 并挂 AppConfig.keychainAllowed 门")
        }
    }
}
