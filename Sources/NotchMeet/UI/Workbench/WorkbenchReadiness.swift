import AppKit

/// 右栏：战备度。真值来源与菜单自检同一套（ControlPanel.Health），不另造一套判定；
/// 「准备面试」按钮是整个驾驶舱的终点——武装画像、预热连接、收入刘海待命。
final class WBReadinessRail: SectionScroll {
    private let healthProvider: () -> ControlPanel.Health
    private let bankCountProvider: () -> Int
    private let ammoProgressProvider: () -> (confirmed: Int, total: Int)
    private let activeTargetProvider: () -> InterviewTarget?
    private let onPrepare: () -> Void
    private let onBuildBank: () -> Void

    private var w: WBStrings { WBStrings(language: AppLanguageStore.shared.language) }

    init(healthProvider: @escaping () -> ControlPanel.Health,
         bankCountProvider: @escaping () -> Int,
         ammoProgressProvider: @escaping () -> (confirmed: Int, total: Int),
         activeTargetProvider: @escaping () -> InterviewTarget?,
         onPrepare: @escaping () -> Void,
         onBuildBank: @escaping () -> Void) {
        self.healthProvider = healthProvider
        self.bankCountProvider = bankCountProvider
        self.ammoProgressProvider = ammoProgressProvider
        self.activeTargetProvider = activeTargetProvider
        self.onPrepare = onPrepare
        self.onBuildBank = onBuildBank
        super.init(frame: .zero)
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func refresh() {
        let w = self.w
        let s = AppStrings.current
        let health = healthProvider()
        let target = activeTargetProvider()
        var rows: [NSView] = []

        rows.append(SKText.label(w.readinessHeader, font: SK.font(17, .semibold), color: SK.ink))
        rows.append(SKBuild.padded(SKBuild.divider(), top: 12, bottom: 4))

        // 弹药确认进度：确认动作直接推动这根条——「点亮按钮」的仪式路径。
        let progress = ammoProgressProvider()
        let bar = WBProgressBar()
        bar.progress = progress.total == 0 ? 0 : CGFloat(progress.confirmed) / CGFloat(progress.total)
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.heightAnchor.constraint(equalToConstant: 5).isActive = true
        rows.append(SKBuild.padded(
            SKText.label(w.ammoProgress(progress.confirmed, progress.total),
                         font: SK.font(12, .medium), color: SK.ink), top: 12, bottom: 6))
        rows.append(SKBuild.padded(bar, top: 0, bottom: 12))

        // 自检行（与菜单同真值）。
        func check(_ label: String, _ mark: String, _ value: String) -> NSView {
            let row = NSStackView(views: [
                SKText.label(label, font: SK.font(11.5), color: SK.secondary),
                SKBuild.spacer(min: 6),
                SKText.label("\(mark) \(value)", font: SK.font(11.5, .medium),
                             color: mark == "✓" ? SK.ink : (mark == "⚠️" ? SK.warning : SK.tertiary)),
            ])
            row.orientation = .horizontal
            row.alignment = .firstBaseline
            return SKBuild.padded(row, top: 4, bottom: 4)
        }

        rows.append(check(w.checkInterviewLanguage, "・", s.interviewLanguageName))
        let sttOK = ProviderRegistry.sttResolution() != .mock
        rows.append(check(w.checkStt, sttOK ? "✓" : "⚠️", sttOK ? "" : w.mockMode))
        if let llm = health.llm {
            rows.append(check(w.checkLLM, health.llmChinaBlocked ? "⚠️" : "✓", llm))
        } else {
            rows.append(check(w.checkLLM, "✗", w.notConfigured))
        }
        rows.append(check(w.checkGuard, health.screenShareGuard ? "✓" : "⚠️", ""))
        if let credit = health.creditSeconds {
            let mark = credit <= 0 ? "✗" : (credit <= 600 ? "⚠️" : "✓")
            rows.append(check(w.checkCredit, mark, s.creditMinutes(credit)))
        }
        // 稿件绑定：绑定关系在目标上（一司一稿），不是全局 activeID。
        if let target {
            if let script = health.activeScript, target.scriptID != nil {
                rows.append(check(w.checkScript, "✓", script))
            } else {
                rows.append(check(w.checkScript, "・", w.scriptNone))
            }
        }

        // 预生成答案库。
        let bankCount = bankCountProvider()
        let buildBtn = SKButton(w.bankBuild, systemImage: "sparkles", kind: .plain) { [weak self] in
            self?.onBuildBank()
        }
        let bankRow = NSStackView(views: [
            SKText.label(w.checkBank, font: SK.font(11.5), color: SK.secondary),
            SKBuild.spacer(min: 6),
            SKText.label(bankCount > 0 ? "✓ \(w.bankCount(bankCount))" : "・",
                         font: SK.font(11.5, .medium), color: bankCount > 0 ? SK.ink : SK.tertiary),
            buildBtn,
        ])
        bankRow.orientation = .horizontal
        bankRow.alignment = .centerY
        bankRow.spacing = 4
        rows.append(SKBuild.padded(bankRow, top: 4, bottom: 8))

        rows.append(SKBuild.padded(SKBuild.divider(), top: 8, bottom: 14))

        // 终点按钮：没选目标时置灰并说明原因——不给「看起来能按其实没反应」的按钮。
        let prepare = SKButton(w.prepare, systemImage: "play.fill", kind: .primary) { [weak self] in
            self?.onPrepare()
        }
        prepare.isEnabledFlag = target != nil
        prepare.translatesAutoresizingMaskIntoConstraints = false
        prepare.heightAnchor.constraint(equalToConstant: 40).isActive = true
        rows.append(prepare)
        rows.append(SKBuild.padded(
            SKBuild.help(target == nil ? w.prepareHintNoTarget : w.prepareHintReady),
            top: 8, bottom: 16))

        scroll.setRows(rows)
        if let first = scroll.stack.arrangedSubviews.first { scroll.gap(4, after: first) }
    }
}

/// 细进度条：轨道 + 光场同款品牌青-蓝渐变填充。
final class WBProgressBar: FlippedView {
    var progress: CGFloat = 0 { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let b = bounds
        let track = CGPath(roundedRect: b, cornerWidth: b.height / 2, cornerHeight: b.height / 2,
                           transform: nil)
        ctx.addPath(track)
        ctx.setFillColor(SK.ink(0.08).cgColor)
        ctx.fillPath()
        let clamped = max(0, min(1, progress))
        guard clamped > 0 else { return }
        let fillRect = CGRect(x: 0, y: 0, width: max(b.height, b.width * clamped), height: b.height)
        let fill = CGPath(roundedRect: fillRect, cornerWidth: b.height / 2,
                          cornerHeight: b.height / 2, transform: nil)
        ctx.fillLinear(fill, fillRect, [(SK.accentHi, 0), (SK.accentLo, 1)])
    }
}
