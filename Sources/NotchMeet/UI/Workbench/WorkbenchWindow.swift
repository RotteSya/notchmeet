import AppKit

/// 备战工作台窗口（高频备战面）。设置窗保持低频配置面不变；两窗共享同一批 live store。
/// 窗口纪律与 SettingsWindowController 完全同款：跨关闭保活（导航/滚动位置/Metal 背景），
/// `.accessory` 直接拿 key（面试中打开不进 Dock/⌘Tab），屏幕共享排除。
final class WorkbenchWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var root: WorkbenchRoot?
    private let targets: TargetStore
    private let scripts: ScriptStore
    private let facts: FactStore

    /// 打开设置窗（深度编辑入口：原稿/事实全文）。
    var onOpenSettings: ((SettingsSection) -> Void)?
    /// 「准备面试」——armed 管线 + 飞入刘海（AppController 接）。
    var onPrepare: ((InterviewTarget) -> Void)?
    /// 在工作台里选中目标 = 武装它（与菜单栏共用 AppController.applyTarget 这一条路径）。
    var onArmTarget: ((String?) -> Void)?
    var onBuildBank: (() -> Void)?
    /// 事实/目标变更后重建画像与热词。
    var onPipelineChanged: (() -> Void)?
    /// 战备度自检快照（复用菜单自检的真值来源，不另造一套）。
    var healthProvider: (() -> ControlPanel.Health)?
    var bankCountProvider: (() -> Int)?

    init(targets: TargetStore, scripts: ScriptStore, facts: FactStore) {
        self.targets = targets
        self.scripts = scripts
        self.facts = facts
        super.init()
    }

    /// 飞入动画要缩的就是这扇窗（任务 6 的舞台入口）。
    var windowForFlight: NSWindow? { window }

    /// 飞行薄片的内容模型（直绘快照的素材，与三栏同一批 live 数据）。
    func flightSheetModel() -> GenieFlight.SheetModel? {
        root?.flightSheetModel(health: healthProvider?() ?? .empty)
    }

    func show() {
        if let window, let root {
            root.refresh()
            root.setRunning(true)
            present(window)
            return
        }
        let root = WorkbenchRoot(
            targets: targets, scripts: scripts, facts: facts,
            onOpenSettings: { [weak self] section in self?.onOpenSettings?(section) },
            onPrepare: { [weak self] target in self?.onPrepare?(target) },
            onArmTarget: { [weak self] id in self?.onArmTarget?(id) },
            onBuildBank: { [weak self] in self?.onBuildBank?() },
            onPipelineChanged: { [weak self] in self?.onPipelineChanged?() },
            healthProvider: { [weak self] in self?.healthProvider?() ?? .empty },
            bankCountProvider: { [weak self] in self?.bankCountProvider?() ?? 0 }
        )

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 660),
            styleMask: [.titled, .fullSizeContentView, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isMovableByWindowBackground = true
        window.backgroundColor = SK.bg
        window.appearance = NSAppearance(named: .darkAqua)
        window.animationBehavior = .documentWindow
        window.contentMinSize = NSSize(width: 920, height: 580)
        window.isReleasedWhenClosed = false
        // 弹药面板上全是公司名与个人经历——绝不能进共享帧。DEBUG 视觉 QA 同款豁口。
        #if DEBUG
        window.sharingType = SettingsWindowController.visualQA ? .readOnly : .none
        #else
        window.sharingType = .none
        #endif
        window.delegate = self
        window.contentView = root
        window.center()

        self.window = window
        self.root = root
        present(window)
    }

    /// 引导移交的简历：先确保窗口在场，再交给弹药面板走完整导入流。
    func importResume(_ url: URL) {
        show()
        root?.importResume(url)
    }

    /// 飞入动画结束后由 AppController 调用：真窗已被快照替身接管，安静收起。
    func hideForFlight() {
        window?.orderOut(nil)
        root?.setRunning(false)
    }

    private func present(_ window: NSWindow) {
        // 同 SettingsWindow：保持 .accessory 直接拿 key，不切 .regular（Dock/⌘Tab 暴露）。
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        #if DEBUG
        if SettingsWindowController.visualQA {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                try? "\(window.windowNumber)".write(toFile: "/tmp/nm-workbench-window.txt",
                                                    atomically: true, encoding: .utf8)
                NSLog("FI_WORKBENCH_WINDOW=%ld key=%d", window.windowNumber,
                      window.isKeyWindow ? 1 : 0)
            }
        }
        #endif
    }

    func windowWillClose(_ notification: Notification) {
        root?.setRunning(false)
    }
}
