import AppKit
import Combine

/// 备战驾驶舱的三栏骨架：目标栏（玻璃轨）｜弹药验证面板｜战备度栏。
/// 掌控感的工程定义：凡是会影响面试当场行为的状态，都在这一屏可见、可点、可改。
final class WorkbenchRoot: NSView {
    private let targets: TargetStore
    private let scripts: ScriptStore
    private let facts: FactStore
    private let onOpenSettings: (SettingsSection) -> Void
    private let onPrepare: (InterviewTarget) -> Void
    private let onArmTarget: (String?) -> Void
    private let onBuildBank: () -> Void
    private let onPipelineChanged: () -> Void
    private let healthProvider: () -> ControlPanel.Health
    private let bankCountProvider: () -> Int

    private let backdrop = SettingsBackdrop()
    private let glass = SidebarGlass()
    private let rail: WBTargetRail
    private let ammoPlane = ContentPlaneView()
    private var ammo: WBAmmoPanel!
    private let readinessPlane = ContentPlaneView()
    private var readiness: WBReadinessRail!

    private let railWidth: CGFloat = 220
    private let readinessWidth: CGFloat = 300

    private var cancellables: [AnyCancellable] = []

    init(targets: TargetStore, scripts: ScriptStore, facts: FactStore,
         onOpenSettings: @escaping (SettingsSection) -> Void,
         onPrepare: @escaping (InterviewTarget) -> Void,
         onArmTarget: @escaping (String?) -> Void,
         onBuildBank: @escaping () -> Void,
         onPipelineChanged: @escaping () -> Void,
         healthProvider: @escaping () -> ControlPanel.Health,
         bankCountProvider: @escaping () -> Int) {
        self.targets = targets
        self.scripts = scripts
        self.facts = facts
        self.onOpenSettings = onOpenSettings
        self.onPrepare = onPrepare
        self.onArmTarget = onArmTarget
        self.onBuildBank = onBuildBank
        self.onPipelineChanged = onPipelineChanged
        self.healthProvider = healthProvider
        self.bankCountProvider = bankCountProvider
        self.rail = WBTargetRail(targets: targets)
        super.init(frame: NSRect(x: 0, y: 0, width: 1000, height: 660))
        wantsLayer = true

        glass.embed(rail, cornerRadius: 0)
        addSubview(backdrop)
        addSubview(glass)
        addSubview(ammoPlane)
        addSubview(readinessPlane)

        ammo = WBAmmoPanel(targets: targets, scripts: scripts, facts: facts,
                           onOpenSettings: onOpenSettings,
                           onChanged: { [weak self] in self?.modelChanged() })
        ammo.currentTarget = { [weak self] in self?.rail.selectedTarget }
        mount(ammo, in: ammoPlane)

        readiness = WBReadinessRail(
            healthProvider: healthProvider,
            bankCountProvider: bankCountProvider,
            ammoProgressProvider: { [weak self] in self?.ammoProgress() ?? (0, 0) },
            activeTargetProvider: { [weak self] in self?.targets.active },
            onPrepare: { [weak self] in
                guard let self, let target = self.targets.active else { return }
                self.onPrepare(target)
            },
            onBuildBank: onBuildBank)
        mount(readiness, in: readinessPlane)

        // 武装走 AppController 的单一路径；武装完成后三栏一起刷新（右栏的稿件绑定
        // 行读的是管线真值，必须在 applyTarget 之后再读，否则显示上一家的稿）。
        rail.onArmTarget = { [weak self] id in
            self?.onArmTarget(id)
            self?.ammo.reloadForSelection()
            self?.readiness.refresh()
        }
        rail.onSelectionChanged = { [weak self] in
            self?.ammo.reloadForSelection()
            self?.readiness.refresh()
        }

        // 目标/稿件库变化（含菜单栏里的改动）→ 三栏一起跟上。
        targets.$library.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.rail.reload()
                self?.readiness.refresh()
            }.store(in: &cancellables)
        scripts.$library.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.ammo.reloadForSelection()
                self?.readiness.refresh()
            }.store(in: &cancellables)

        // 界面语言/面试语言变化：整体重建文案（同 SettingsRoot 的重建路径）。
        AppLanguageStore.shared.$language.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }.store(in: &cancellables)
        NotificationCenter.default.addObserver(
            forName: .nmInterviewLanguageChanged, object: nil, queue: .main
        ) { [weak self] _ in DispatchQueue.main.async { self?.refresh() } }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let b = bounds
        backdrop.frame = b
        glass.frame = NSRect(x: 0, y: 0, width: railWidth, height: b.height)
        let centerWidth = max(0, b.width - railWidth - readinessWidth)
        ammoPlane.frame = NSRect(x: railWidth, y: 0, width: centerWidth, height: b.height)
        readinessPlane.frame = NSRect(x: railWidth + centerWidth, y: 0,
                                      width: readinessWidth, height: b.height)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        backdrop.setRunning(window != nil)
        // 整体 refresh 而不是只 reload 目标栏：rail.reload() 会把初始选中解析到
        // 武装目标，弹药面板与战备度必须跟着这次解析走，否则首屏三栏各说各话。
        refresh()
    }

    /// 重开窗口 / 语言变化时刷新三栏（store 都是 live 的，重建即最新）。
    func refresh() {
        rail.reload()
        ammo.reloadForSelection()
        readiness.refresh()
    }

    /// 引导移交的简历：直接走弹药面板的完整导入流（含分流、隐私/额度门与状态反馈）。
    func importResume(_ url: URL) { ammo.importFile(url) }

    /// 飞行薄片的内容模型：与三栏同一批 live 数据（直绘快照的素材）。
    func flightSheetModel(health: ControlPanel.Health) -> GenieFlight.SheetModel {
        let w = WBStrings.current
        let s = AppStrings.current
        let sheet = facts.sheet
        let railRows = targets.all.map { target -> GenieFlight.SheetModel.RailRow in
            let sub = [target.role, target.stage].compactMap { $0 }.filter { !$0.isEmpty }
                .joined(separator: " · ")
            return GenieFlight.SheetModel.RailRow(
                title: target.company,
                subtitle: sub.isEmpty ? nil : sub,
                armed: target.id == targets.activeID)
        }
        var cards: [GenieFlight.SheetModel.Card] = sheet.experiences.map { e in
            var title = [e.role, e.org].filter { !$0.isEmpty }.joined(separator: " @ ")
            if !e.period.isEmpty { title += "（\(e.period)）" }
            let detail = (e.actions + e.results).joined(separator: "、")
            return .init(title: title, detail: detail, locked: e.locked == true)
        }
        cards += sheet.motivations.map {
            .init(title: $0.statement, detail: $0.careerAxis ?? "", locked: $0.locked == true)
        }
        let progress = ammoProgress()
        var rows: [(String, String)] = [(w.checkInterviewLanguage, s.interviewLanguageName)]
        rows.append((w.checkLLM, health.llm ?? w.notConfigured))
        rows.append((w.checkGuard, health.screenShareGuard ? "✓" : "⚠️"))
        if let script = health.activeScript { rows.append((w.checkScript, script)) }
        return GenieFlight.SheetModel(
            windowTitle: w.windowTitle,
            railRows: railRows,
            centerTitle: targets.active?.company ?? w.globalAmmo,
            cards: cards,
            readinessTitle: w.readinessHeader,
            readinessRows: rows,
            progressLabel: w.ammoProgress(progress.confirmed, progress.total),
            progress: progress.total == 0 ? 0 : CGFloat(progress.confirmed) / CGFloat(progress.total))
    }

    func setRunning(_ running: Bool) { backdrop.setRunning(running) }

    private func modelChanged() {
        readiness.refresh()
        rail.reload()
        onPipelineChanged()
    }

    /// 弹药确认进度 = locked 的经历+动机 / 总数（备忘不参与——它们没有确认语义）。
    private func ammoProgress() -> (confirmed: Int, total: Int) {
        let sheet = facts.sheet
        let total = sheet.experiences.count + sheet.motivations.count
        let confirmed = sheet.experiences.filter { $0.locked == true }.count
            + sheet.motivations.filter { $0.locked == true }.count
        return (confirmed, total)
    }

    private func mount(_ view: NSView, in host: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            view.topAnchor.constraint(equalTo: host.topAnchor, constant: 6),
            view.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
    }
}
