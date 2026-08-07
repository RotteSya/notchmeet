import AppKit

/// 屏幕共享闸门（PLAN §3 S4）：这个 app 弹出的**任何**一块 UI 都不能进入面试官看到的帧。
///
/// 刘海面板（`NotchPanel`）与设置窗口（`SettingsWindowController`）在各自的构造点已经设过
/// `sharingType = .none`。这里补齐两类「窗口不由我们构造」的表面——它们此前一律是 AppKit
/// 默认的 `.readOnly`，也就是会被屏幕录制与 Zoom/Meet/Teams 的共享完整拍进去：
///
///   * `NSAlert` —— 窗口由 AppKit 造。用下面的 `runModalGuarded()` /
///     `beginSheetModalGuarded(for:)` 代替原生调用即可。sheet 是独立窗口，**不**继承
///     宿主窗口的 sharingType，所以设置窗口里的 sheet 同样要走这里。
///   * `NSMenu` —— 弹出用的是 AppKit 私有窗口 `NSPopupMenuWindow`，没有构造点可挂，且每次
///     弹出都是**新**窗口（不复用 → 预先造一个打标无效），只能每次弹出时补设。自己创建的
///     菜单用 `protect(_:)`（`menuWillOpen` 同步排除，零帧泄漏）；非我们创建的菜单靠
///     `installMenuGuard()` 的复扫兜底。实测细节见 `excludeMenuWindowsNow()` 的注释。
///
/// 注意：这只屏蔽软件采集，挡不住对着屏幕的摄像头。
enum ScreenShareGuard {

    /// 本地视觉 QA 逃生口（DEBUG 专用），与 `NotchPanel` / `SettingsWindowController` 同源：
    /// release 构建无论环境变量如何都保持排除。
    static var visualQA: Bool {
        let process = ProcessInfo.processInfo
        return process.environment["FI_VISUAL_QA"] == "1"
            || process.arguments.contains("--visual-qa")
    }

    /// 该打给窗口的 sharingType：release 永远 `.none`；DEBUG + QA 开关下降级为 `.readOnly`
    /// 以便本地截图。
    static var sharingType: NSWindow.SharingType {
        #if DEBUG
        return visualQA ? .readOnly : .none
        #else
        return .none
        #endif
    }

    /// 把一个我们持有的窗口排除出屏幕采集。
    static func exclude(_ window: NSWindow?) {
        window?.sharingType = sharingType
    }

    // MARK: - 自检

    /// 自检菜单里那行「画面共有ガード」的真话版：审计**本进程全部窗口**，而不是只看
    /// 刘海面板一个（旧实现只查 NotchPanel，设置窗/引导窗/弹窗全都不在结论里——字面真
    /// 语义假）。任何一个可见窗口的 sharingType 偏离策略值即不通过。
    ///
    /// 菜单窗口除外：它们有自己的零帧闸门（`menuWillOpen`），而这次审计恰恰是在菜单
    /// 弹出过程中（`menuNeedsUpdate`）跑的——那一刻菜单窗口可能还没来得及被补设。
    /// 不可见窗口除外：不上屏的窗口进不了共享帧，而设置窗关闭后是保活的隐藏窗口。
    static func auditPasses() -> Bool {
        unprotectedWindows(in: NSApp.windows).isEmpty
    }

    /// 审计核心（纯函数，供测试直接喂窗口列表）：返回会被屏幕共享拍进去的窗口。
    static func unprotectedWindows(in windows: [NSWindow]) -> [NSWindow] {
        let want = sharingType
        return windows.filter { $0.isVisible && !isMenuWindow($0) && $0.sharingType != want }
    }

    // MARK: - 菜单窗口

    /// 菜单窗口的正解闸门：`menuWillOpen` 时窗口**已创建、尚未上屏**（实测 CGWindow
    /// `onscreen=false`），这里同步补设 ＝ 零帧泄漏。我们自己创建的菜单都从这条路走。
    ///
    /// 为什么不能靠别的时机（macOS 26.5 实测时间线，popUp 记为 0）：
    ///   * `didBeginTracking` ~4ms —— 窗口还没建，无从下手。
    ///   * 窗口进入 `NSApp.windows` 与 CGWindow 上屏的先后**没有保证**，都可能落在
    ///     40〜200ms 间；只靠 30Hz 复扫，8 次里抓到过 1 次「onscreen=true alpha=1
    ///     sharing=1」持续 ~50ms ＝ 屏幕共享里 1〜2 帧的完整菜单。
    ///   * `DispatchQueue.main.async` 在菜单跟踪期间**不可靠**：实测 1.8s 都没排到。
    static func excludeMenuWindowsNow() { _ = excludeMenuWindows() }

    /// 给一个我们创建的菜单挂上闸门（`menuWillOpen` → 同步排除）。
    /// 已有 delegate 的菜单不会被抢——那种菜单要在自己的 `menuWillOpen` 里调用
    /// `excludeMenuWindowsNow()`（见 `ControlPanel`）。
    static func protect(_ menu: NSMenu) {
        guard menu.delegate == nil else { return }
        menu.delegate = menuDelegate
    }

    private static let menuDelegate = MenuGuardDelegate()

    // MARK: - 兜底：AppKit 随手创建的窗口

    /// 进程启动时装一次的总兜底：AppKit 会在我们看不见的地方创建窗口——实机确认的有
    /// `TUINSWindow`（TextInputUI：长按选字、预测候选，输入时**会上屏**，且默认
    /// sharing=readOnly），同类还有 tooltip、拖拽影像等。这些窗口没有构造点可挂，
    /// 但任何窗口上屏前后必然经过 update/draw → `didUpdateNotification`，在那一刻补设。
    /// 已排除的窗口只付一次指针比较，开销可忽略。
    static func installWindowGuard() {
        guard !windowGuardInstalled else { return }
        windowGuardInstalled = true
        NotificationCenter.default.addObserver(
            forName: NSWindow.didUpdateNotification, object: nil, queue: nil
        ) { note in
            guard let w = note.object as? NSWindow, w.sharingType != sharingType else { return }
            w.sharingType = sharingType
        }
    }

    private static var windowGuardInstalled = false

    private static var installed = false
    private static var sweep: Timer?
    private static var idleTicks = 0

    /// 兜底闸门，进程启动时装一次：不是我们创建的菜单（AppKit 自带的文本右键菜单等）没有
    /// delegate 可挂，只能在菜单会话期间以 30Hz 复扫——最坏暴露 ~1 帧，好过永久可见。
    /// 也顺带覆盖悬停才创建的子菜单窗口。
    static func installMenuGuard() {
        guard !installed else { return }
        installed = true
        NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil
        ) { _ in startSweep() }
    }

    private static func startSweep() {
        idleTicks = 0
        guard sweep == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { _ in tick() }
        timer.tolerance = 0.01
        // 菜单跟踪期间 run loop 在 event-tracking mode —— 必须 .common，否则整段不走表。
        RunLoop.main.add(timer, forMode: .common)
        sweep = timer
    }

    /// 菜单窗口连续消失 0.5s ＝ 这一轮菜单会话结束（含悬停打开的子菜单）→ 停表，待机零开销。
    private static func tick() {
        idleTicks = excludeMenuWindows() ? 0 : idleTicks + 1
        guard idleTicks > 15 else { return }
        sweep?.invalidate()
        sweep = nil
    }

    /// 返回本次是否看到菜单窗口（用于判断菜单会话是否结束）。
    private static func excludeMenuWindows() -> Bool {
        let want = sharingType
        var seen = false
        for window in NSApp.windows where isMenuWindow(window) {
            seen = true
            if window.sharingType != want { window.sharingType = want }
        }
        return seen
    }

    /// AppKit 私有类：当前是 `NSPopupMenuWindow`（历史上还有 `NSCarbonMenuWindow`），都以
    /// MenuWindow 结尾。按类名后缀匹配，永远不会误伤我们自己的窗口。
    static func isMenuWindow(_ window: NSWindow) -> Bool {
        String(describing: type(of: window)).hasSuffix("MenuWindow")
    }
}

/// 只做一件事的共享 delegate：菜单即将展示时把它的窗口排除出屏幕采集。
private final class MenuGuardDelegate: NSObject, NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) { ScreenShareGuard.excludeMenuWindowsNow() }
}

extension NSAlert {
    /// `runModal()` 的替代：先把 alert 自己的窗口排除出屏幕共享，再弹。
    @discardableResult
    func runModalGuarded() -> NSApplication.ModalResponse {
        ScreenShareGuard.exclude(window)
        return runModal()
    }

    /// `beginSheetModal(for:)` 的替代——sheet 有自己的窗口，宿主窗口的排除不会继承下来。
    func beginSheetModalGuarded(for sheetWindow: NSWindow,
                                completionHandler handler: ((NSApplication.ModalResponse) -> Void)? = nil) {
        ScreenShareGuard.exclude(window)
        beginSheetModal(for: sheetWindow, completionHandler: handler)
    }
}
