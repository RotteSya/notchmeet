import AppKit

/// 左栏：面试目标列表（公司维度）。选中某个目标 = 把它设为「武装目标」
/// （`TargetStore.activeID`，与菜单栏、armed 管线同一真相源）；「通用弹药库」
/// 只是查看视角，不动武装选择。
final class WBTargetRail: FlippedView {
    enum Selection: Equatable {
        case target(String)
        case global
    }

    private let targets: TargetStore
    private(set) var selection: Selection = .global
    var onSelectionChanged: (() -> Void)?
    /// 武装某个目标。**必须**走这条回调（最终落到 AppController.applyTarget），
    /// 而不是就地 `targets.setActive`——武装 = 设活跃 + 兑现绑定用稿 + 切答案库 +
    /// 重建画像 + 下发热词。就地 setActive 只改了第一项，右栏「稿件绑定」会与左栏
    /// 选中的公司对不上，面试当场读的还是上一家的稿（真机首测即撞到）。
    var onArmTarget: ((String?) -> Void)?

    private var rows: [WBTargetRow] = []
    private var globalRow: WBTargetRow?
    private let pill = PillView()
    private let header = SKText.label("", font: SK.font(11, .semibold), color: SK.tertiary, tracking: 0.6)
    private var addButton: SKButton!
    private var pillSpring = Spring(0, stiffness: 360, damping: 30)
    private var loop: DisplayLoop?

    private let trafficClearance: CGFloat = 34
    private let identityHeight: CGFloat = 50
    private let rowH: CGFloat = 46
    private let globalRowH: CGFloat = 38
    private let sideInset: CGFloat = 12

    init(targets: TargetStore) {
        self.targets = targets
        super.init(frame: .zero)
        addSubview(pill)
        addSubview(header)
        addButton = SKButton(WBStrings.current.newTarget, systemImage: "plus", kind: .plain) { [weak self] in
            self?.addTarget()
        }
        addSubview(addButton)
        loop = DisplayLoop(host: self)
        loop?.onTick = { [weak self] dt in self?.tick(dt) ?? false }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func reload() {
        let w = WBStrings.current
        header.stringValue = w.targetsHeader.uppercased()
        addButton.removeFromSuperview()
        addButton = SKButton(w.newTarget, systemImage: "plus", kind: .plain) { [weak self] in
            self?.addTarget()
        }
        addSubview(addButton)

        rows.forEach { $0.removeFromSuperview() }
        globalRow?.removeFromSuperview()

        // 武装目标始终是选中态的默认解释：工作台重开时回到「你要打的那一仗」。
        if case .target(let id) = selection, !targets.all.contains(where: { $0.id == id }) {
            selection = targets.activeID.map(Selection.target) ?? .global
        } else if selection == .global, let active = targets.activeID, rows.isEmpty {
            selection = .target(active)
        }

        rows = targets.all.map { target in
            let row = WBTargetRow(title: target.company,
                                  subtitle: subtitle(for: target),
                                  icon: "building.2",
                                  isArmed: target.id == targets.activeID)
            row.onTap = { [weak self] in self?.select(.target(target.id)) }
            row.onDelete = { [weak self] in self?.confirmDelete(target) }
            addSubview(row)
            return row
        }
        let g = WBTargetRow(title: w.globalAmmo, subtitle: nil, icon: "shippingbox", isArmed: false)
        g.onTap = { [weak self] in self?.select(.global) }
        globalRow = g
        addSubview(g)

        applySelectionHighlight()
        needsLayout = true
        needsDisplay = true
        placePillImmediately()
    }

    var selectedTarget: InterviewTarget? {
        guard case .target(let id) = selection else { return nil }
        return targets.all.first { $0.id == id }
    }

    private func subtitle(for target: InterviewTarget) -> String? {
        let parts = [target.role, target.stage].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func addTarget() {
        guard let id = targets.add(company: WBStrings.current.newTargetDefaultName) else { return }
        onArmTarget?(id)
        selection = .target(id)
        reload()
        onSelectionChanged?()
    }

    private func confirmDelete(_ target: InterviewTarget) {
        let w = WBStrings.current
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "\(w.deleteTarget) — \(target.company)"
        alert.informativeText = w.deleteTargetConfirm
        alert.addButton(withTitle: AppStrings.current.deleteButton)
        alert.addButton(withTitle: AppStrings.current.cancel)
        guard let window else { return }
        alert.beginSheetModalGuarded(for: window) { [weak self] resp in
            guard resp == .alertFirstButtonReturn, let self else { return }
            self.targets.remove(id: target.id)
            if case .target(let id) = self.selection, id == target.id { self.selection = .global }
            self.reload()
            self.onSelectionChanged?()
        }
    }

    private func select(_ s: Selection) {
        guard s != selection else { return }
        selection = s
        // 选中一个目标 = 武装它（整条链，不只是 activeID）。「通用弹药库」只是查看
        // 视角，不动武装选择——不然点一下浏览就把本场目标解除了。
        if case .target(let id) = s { onArmTarget?(id) }
        applySelectionHighlight()
        animatePill()
        onSelectionChanged?()
    }

    private func applySelectionHighlight() {
        for (i, row) in rows.enumerated() {
            row.isSelectedRow = selection == .target(targets.all[i].id)
            row.isArmed = targets.all[i].id == targets.activeID
        }
        globalRow?.isSelectedRow = selection == .global
    }

    // MARK: - Layout & pill

    private var navTop: CGFloat { trafficClearance + identityHeight + 30 }

    override func layout() {
        super.layout()
        let w = bounds.width
        header.frame = NSRect(x: sideInset + 10, y: trafficClearance + identityHeight + 8,
                              width: w - sideInset * 2, height: 14)
        for (i, row) in rows.enumerated() {
            row.frame = NSRect(x: sideInset, y: navTop + CGFloat(i) * rowH,
                               width: w - sideInset * 2, height: rowH)
        }
        let gy = navTop + CGFloat(rows.count) * rowH + 10
        globalRow?.frame = NSRect(x: sideInset, y: gy, width: w - sideInset * 2, height: globalRowH)
        addButton.frame = NSRect(x: sideInset + 2, y: gy + globalRowH + 12,
                                 width: w - sideInset * 2 - 4, height: 30)
        positionPill(at: pillSpring.value)
    }

    /// pill 的弹簧值 = 选中行的序号；「通用弹药库」用 rows.count 表示。
    private func selectionIndex() -> CGFloat {
        switch selection {
        case .target(let id):
            return CGFloat(targets.all.firstIndex { $0.id == id } ?? 0)
        case .global:
            return CGFloat(rows.count)
        }
    }

    private func positionPill(at value: CGFloat) {
        let w = bounds.width
        let n = CGFloat(rows.count)
        let clamped = max(0, min(value, n))
        // 目标行段是均匀 rowH；global 行隔 10pt 间隙、矮一档——最后一段单独插值，
        // 弹簧飞过边界时高度与位置一起渐变。
        let y: CGFloat
        let h: CGFloat
        if rows.isEmpty {
            y = navTop + 10 + 2
            h = globalRowH - 4
        } else if clamped <= n - 1 {
            y = navTop + clamped * rowH + 2
            h = rowH - 4
        } else {
            let t = min(1, clamped - (n - 1))
            let lastY = navTop + (n - 1) * rowH
            let globalY = navTop + n * rowH + 10
            y = skLerp(lastY, globalY, t) + 2
            h = skLerp(rowH, globalRowH, t) - 4
        }
        pill.frame = NSRect(x: sideInset, y: y, width: w - sideInset * 2, height: h)
        pill.isHidden = rows.isEmpty && globalRow == nil
    }

    private func placePillImmediately() {
        pillSpring.snap(selectionIndex())
        positionPill(at: pillSpring.value)
    }

    private func animatePill() {
        if SKMotion.reduced {
            placePillImmediately()
        } else {
            pillSpring.target = selectionIndex()
            loop?.start()
        }
    }

    private func tick(_ dt: CGFloat) -> Bool {
        let moving = pillSpring.step(dt)
        positionPill(at: pillSpring.value)
        return moving
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        // 同设置侧栏：身份区（图标 + 名字）盖在玻璃上。
        let iconSize: CGFloat = 26
        let iconRect = CGRect(x: 22, y: trafficClearance + (identityHeight - iconSize) / 2 - 4,
                              width: iconSize, height: iconSize)
        if let icon = OB.icon() {
            ctx.saveGState()
            let clip = CGPath(roundedRect: iconRect, cornerWidth: iconSize * 0.23,
                              cornerHeight: iconSize * 0.23, transform: nil)
            ctx.addPath(clip); ctx.clip()
            icon.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1)
            ctx.restoreGState()
            ctx.addPath(clip)
            ctx.setStrokeColor(SK.ink(0.18).cgColor)
            ctx.setLineWidth(SK.hairline(self)); ctx.strokePath()
        }
        let name = SKText.attributed("NotchMeet", font: SK.font(15, .semibold), color: SK.ink, tracking: -0.2)
        name.draw(at: CGPoint(x: iconRect.maxX + 11, y: iconRect.minY - 1))
        let sub = SKText.attributed(WBStrings.current.windowTitle, font: SK.font(11.5), color: SK.secondary)
        sub.draw(at: CGPoint(x: iconRect.maxX + 11, y: iconRect.minY + 14))
    }
}

/// 一行目标：公司名（+ 岗位·阶段副行）+ 武装指示点。选中背景由外部 pill 提供。
final class WBTargetRow: NSView {
    private let title: String
    private let subtitle: String?
    private let iconName: String
    var onTap: (() -> Void)?
    var onDelete: (() -> Void)?

    var isSelectedRow = false { didSet { if isSelectedRow != oldValue { needsDisplay = true } } }
    var isArmed: Bool { didSet { if isArmed != oldValue { needsDisplay = true } } }
    private var hovering = false { didSet { if hovering != oldValue { needsDisplay = true } } }
    private var tracking: NSTrackingArea?

    init(title: String, subtitle: String?, icon: String, isArmed: Bool) {
        self.title = title
        self.subtitle = subtitle
        self.iconName = icon
        self.isArmed = isArmed
        super.init(frame: .zero)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds,
                               options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t); tracking = t
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) { onTap?() }
    override func rightMouseDown(with event: NSEvent) {
        guard onDelete != nil else { return }
        let menu = NSMenu()
        // 右键菜单是独立窗口，公司名就在标题里——同门保护。
        ScreenShareGuard.protect(menu)
        let item = NSMenuItem(title: WBStrings.current.deleteTarget,
                              action: #selector(deleteTapped), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
    @objc private func deleteTapped() { onDelete?() }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let b = bounds
        if hovering && !isSelectedRow {
            let path = CGPath(roundedRect: b.insetBy(dx: 0, dy: 2), cornerWidth: 8, cornerHeight: 8, transform: nil)
            ctx.addPath(path); ctx.setFillColor(SK.ink(0.05).cgColor); ctx.fillPath()
        }
        let fg: NSColor = isSelectedRow ? SK.ink : (hovering ? SK.ink.withAlphaComponent(0.92) : SK.secondary)
        if let img = skSymbol(iconName, size: 13, weight: isSelectedRow ? .semibold : .regular,
                              color: isSelectedRow ? SK.accentHi : fg) {
            img.draw(in: CGRect(x: 14, y: b.midY - img.size.height / 2,
                                width: img.size.width, height: img.size.height),
                     from: .zero, operation: .sourceOver, fraction: 1)
        }
        let hasSub = subtitle != nil
        let titleY = hasSub ? b.midY - 16 : b.midY - 8
        let attr = SKText.attributed(title, font: SK.font(13, isSelectedRow ? .medium : .regular),
                                     color: fg, lineBreak: .byTruncatingTail)
        attr.draw(in: CGRect(x: 40, y: titleY, width: b.width - 40 - 16, height: 17))
        if let subtitle {
            let sub = SKText.attributed(subtitle, font: SK.font(10.5), color: SK.tertiary,
                                        lineBreak: .byTruncatingTail)
            sub.draw(in: CGRect(x: 40, y: titleY + 17, width: b.width - 40 - 16, height: 14))
        }
        // 武装指示点：这颗目标就是「准备面试」会武装的那一个。
        if isArmed {
            let dot = CGRect(x: b.width - 14, y: b.midY - 3, width: 6, height: 6)
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: 4, color: SK.accent.withAlphaComponent(0.7).cgColor)
            ctx.setFillColor(SK.accent.cgColor)
            ctx.fillEllipse(in: dot)
            ctx.restoreGState()
        }
    }
}
