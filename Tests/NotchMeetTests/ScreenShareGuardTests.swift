import AppKit
import XCTest
@testable import notchmeet

/// 「面试官看不到这个 app」这句承诺此前只覆盖刘海面板和设置窗口：NSAlert（含 sheet）、
/// 引导窗口、以及所有 NSMenu 的弹出窗口都是 AppKit 默认的 .readOnly ＝ 会被屏幕共享
/// 完整录进去。这组测试守住修好之后的不变量。
@MainActor
final class ScreenShareGuardTests: XCTestCase {

    /// 逃生口只在 DEBUG + 显式 QA 开关下打开；测试进程两个条件都不满足 → 必须是 .none。
    func testGuardExcludesWindowsFromCaptureByDefault() throws {
        try XCTSkipIf(ScreenShareGuard.visualQA, "本地视觉 QA 模式下故意降级为 .readOnly")
        XCTAssertEqual(ScreenShareGuard.sharingType, .none)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.sharingType = .readWrite
        ScreenShareGuard.exclude(window)
        XCTAssertEqual(window.sharingType, .none, "被 guard 过的窗口不能再进屏幕采集")
    }

    /// 菜单窗口只能按 AppKit 私有类名识别。这条是金丝雀：Apple 若改名，
    /// `isMenuWindow` 就会静默失效（菜单又会被录进共享帧），必须由测试先叫出来。
    func testAppKitStillNamesItsMenuWindowSoTheClassifierHolds() {
        XCTAssertNotNil(NSClassFromString("NSPopupMenuWindow"),
                        "AppKit 的菜单窗口类改名了 → ScreenShareGuard.isMenuWindow 需要跟着改")
        XCTAssertTrue("NSPopupMenuWindow".hasSuffix("MenuWindow"))

        let plain = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: true)
        XCTAssertFalse(ScreenShareGuard.isMenuWindow(plain), "不能把我们自己的窗口误判成菜单窗口")
    }

    /// `protect` 给菜单挂上「即将展示 → 排除」的 delegate，但绝不抢已有 delegate
    /// （`ControlPanel` 自己就是 delegate，被抢会连自检刷新一起丢）。
    func testProtectInstallsGuardDelegateWithoutStealingAnExistingOne() {
        let menu = NSMenu()
        ScreenShareGuard.protect(menu)
        XCTAssertNotNil(menu.delegate, "菜单没挂上屏幕共享闸门")

        final class Owner: NSObject, NSMenuDelegate {}
        let owner = Owner()
        let owned = NSMenu()
        owned.delegate = owner
        ScreenShareGuard.protect(owned)
        XCTAssertTrue(owned.delegate === owner, "不能抢走菜单原有的 delegate")
    }

    /// 回归闸门：新建 `NSMenu` 的文件必须自己接上闸门（`protect(_:)`，或像 ControlPanel
    /// 那样在自有 `menuWillOpen` 里调 `excludeMenuWindowsNow()`）。漏一处就是 E3 复发。
    func testEveryFileThatBuildsAMenuWiresTheGuard() throws {
        var offenders: [String] = []
        for file in try swiftSources() {
            let text = try String(contentsOf: file, encoding: .utf8)
            guard text.contains("NSMenu(") else { continue }
            if !text.contains("ScreenShareGuard") { offenders.append(file.lastPathComponent) }
        }
        XCTAssertTrue(offenders.isEmpty,
                      "这些文件创建的菜单会被屏幕共享录进去：" + offenders.joined(separator: ", "))
    }

    /// 回归闸门：新增的弹窗必须走 guard 版本。裸 `alert.runModal()` /
    /// `alert.beginSheetModal(` 一旦回到 Sources 就让测试失败——这正是 E1/E3 的成因。
    func testNoBareAlertPresentationRemainsInSources() throws {
        var offenders: [String] = []
        for file in try swiftSources() {
            let text = try String(contentsOf: file, encoding: .utf8)
            for (i, line) in text.components(separatedBy: "\n").enumerated()
            where line.contains("alert.runModal()") || line.contains("alert.beginSheetModal(") {
                offenders.append("\(file.lastPathComponent):\(i + 1)")
            }
        }
        XCTAssertTrue(offenders.isEmpty,
                      "这些弹窗会被屏幕共享录进去，改用 runModalGuarded()/beginSheetModalGuarded(for:)："
                      + offenders.joined(separator: ", "))
    }

    /// 引导窗口（可从「设置 → 关于 → 重新运行引导」在面试中途重开，里面是原稿全文）
    /// 必须在构造点就被排除。
    func testOnboardingWindowSetsTheGuardAtConstruction() throws {
        let text = try String(contentsOf: repoRoot.appendingPathComponent(
            "Sources/NotchMeet/UI/OnboardingWindow.swift"), encoding: .utf8)
        XCTAssertTrue(text.contains("ScreenShareGuard.exclude("),
                      "OnboardingWindow 少了屏幕共享排除")
    }

    // MARK: - 源码扫描的共用件

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/NotchMeetTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
    }

    /// Sources 下的全部 Swift 文件（闸门自身除外——它当然会出现这些字样）。
    private func swiftSources() throws -> [URL] {
        let sources = repoRoot.appendingPathComponent("Sources")
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" && $0.lastPathComponent != "ScreenShareGuard.swift" } ?? []
        XCTAssertFalse(files.isEmpty, "找不到源文件，路径推导失效")
        return files
    }
}
