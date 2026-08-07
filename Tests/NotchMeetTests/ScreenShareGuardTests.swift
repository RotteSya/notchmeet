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

    /// 回归闸门：文件选择器（导入原稿时列出的正是含公司名的文件名）也是本进程窗口，
    /// 新增的 `NSOpenPanel` 必须在同一文件里接上 ScreenShareGuard。
    func testEveryFileThatOpensAFilePanelWiresTheGuard() throws {
        var offenders: [String] = []
        for file in try swiftSources() {
            let text = try String(contentsOf: file, encoding: .utf8)
            guard text.contains("NSOpenPanel(") || text.contains("NSSavePanel(") else { continue }
            if !text.contains("ScreenShareGuard") { offenders.append(file.lastPathComponent) }
        }
        XCTAssertTrue(offenders.isEmpty,
                      "这些文件的文件选择器会被屏幕共享录进去：" + offenders.joined(separator: ", "))
    }

    /// 回归闸门（E4）：面试中打开任何 UI 都不许把 app 切成 `.regular`——Dock 图标 + ⌘Tab
    /// 条目会直接出现在共享的整屏画面里。accessory app 经 activate 后窗口一样能拿 key。
    func testNothingFlipsTheAppToRegularActivationPolicy() throws {
        var offenders: [String] = []
        for file in try swiftSources() {
            let text = try String(contentsOf: file, encoding: .utf8)
            for (i, line) in text.components(separatedBy: "\n").enumerated()
            where line.contains("setActivationPolicy(.regular)") {
                offenders.append("\(file.lastPathComponent):\(i + 1)")
            }
        }
        XCTAssertTrue(offenders.isEmpty,
                      "切到 .regular 会在面试官共享的画面里亮出 Dock 图标：" + offenders.joined(separator: ", "))
    }

    /// 自检的「画面共有ガード」现在审计全部窗口（E6）：可见且偏离策略值的窗口必须被点名；
    /// 不可见窗口（设置窗关闭后保活）与菜单窗口（有自己的零帧闸门）不参与。
    func testWindowAuditFlagsOnlyVisibleUnprotectedNonMenuWindows() throws {
        try XCTSkipIf(ScreenShareGuard.visualQA, "本地视觉 QA 模式下故意降级为 .readOnly")

        func makeWindow(sharing: NSWindow.SharingType) -> NSWindow {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
                             styleMask: [.borderless], backing: .buffered, defer: false)
            w.sharingType = sharing
            return w
        }

        let leaky = makeWindow(sharing: .readOnly)
        leaky.orderFrontRegardless()                       // 可见 + 可采集 → 必须被点名
        defer { leaky.orderOut(nil) }
        let protected = makeWindow(sharing: .none)
        protected.orderFrontRegardless()                   // 可见但已排除 → 通过
        defer { protected.orderOut(nil) }
        let hidden = makeWindow(sharing: .readOnly)        // 不可见 → 不参与

        let flagged = ScreenShareGuard.unprotectedWindows(in: [leaky, protected, hidden])
        XCTAssertTrue(flagged.contains(where: { $0 === leaky }), "可见的可采集窗口没被审计出来")
        XCTAssertFalse(flagged.contains(where: { $0 === protected }))
        XCTAssertFalse(flagged.contains(where: { $0 === hidden }), "不可见窗口不该拖累自检结论")

        // 菜单窗口按类名后缀豁免（它们的闸门在 menuWillOpen）。
        final class FakeMenuWindow: NSWindow {}
        let menu = FakeMenuWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        menu.sharingType = .readOnly
        menu.orderFrontRegardless()
        defer { menu.orderOut(nil) }
        XCTAssertTrue(ScreenShareGuard.unprotectedWindows(in: [menu]).isEmpty)
    }

    /// 总兜底：AppKit 自建的窗口（实机确认 `TUINSWindow` 输入候选窗默认可采集）没有
    /// 构造点可挂，靠 didUpdate 通知在首次绘制时补设。观察者对任何窗口都生效。
    func testWindowGuardExcludesAnyWindowOnItsFirstUpdate() throws {
        try XCTSkipIf(ScreenShareGuard.visualQA, "本地视觉 QA 模式下故意降级为 .readOnly")
        ScreenShareGuard.installWindowGuard()
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
                         styleMask: [.borderless], backing: .buffered, defer: true)
        w.sharingType = .readOnly
        NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: w)
        XCTAssertEqual(w.sharingType, .none, "didUpdate 兜底没把窗口排除出屏幕采集")
    }

    /// 自检行的取值必须是全窗口审计，不能再只看刘海一个窗口（E6 的成因）。
    func testHealthSnapshotUsesTheGlobalAudit() throws {
        let text = try String(contentsOf: repoRoot.appendingPathComponent(
            "Sources/NotchMeet/App/AppController.swift"), encoding: .utf8)
        XCTAssertTrue(text.contains("screenShareGuard: ScreenShareGuard.auditPasses()"),
                      "自检的屏幕共享行不再取全局审计——「✓」又要变回字面真语义假")
    }

    /// E5 回归：demo 的 TTS 调用点必须把「正在录音」传给 DemoVoice——否则面试中重开
    /// 引导，扬声器朗读的日语问题会被自己的麦克风采进 Zoom。
    func testDemoVoiceCallSitePassesLiveCaptureState() throws {
        let text = try String(contentsOf: repoRoot.appendingPathComponent(
            "Sources/NotchMeet/App/AppController.swift"), encoding: .utf8)
        XCTAssertTrue(text.contains("speakJapanese(spokenJa, liveCaptureActive: recording)"),
                      "runOnboardingDemo 的 TTS 没带 liveCaptureActive: recording 门")
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
