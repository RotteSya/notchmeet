import AppKit
import UniformTypeIdentifiers

/// 中栏：弹药验证面板。信任的三根支柱在这里落地——
///  1. 出处引用：每张卡片显示它抽取自原文的哪个片段（provenance.quote）；
///  2. 逐条确认：草稿虚线框 / 已确认实线（locked），确认权在用户；
///  3. 诚实的不确定：对不齐原文的字段标「AI 不确定，请补全」，绝不静默采信。
final class WBAmmoPanel: SectionScroll {
    private let targets: TargetStore
    private let scripts: ScriptStore
    private let facts: FactStore
    private let onOpenSettings: (SettingsSection) -> Void
    private let onChanged: () -> Void

    private var statusLine: NSTextField?
    /// 导入解析进行中：状态行不被 rebuild 冲掉。
    private var importing = false
    /// 最近一次导入新增的事实 id——重建后这些卡片做错峰浮现。
    private var revealIDs: Set<String> = []

    private var w: WBStrings { WBStrings(language: AppLanguageStore.shared.language) }
    /// 由 Root 注入的「当前选中目标」读取器（nil = 通用弹药库视角）。
    var currentTarget: (() -> InterviewTarget?)?

    private var fieldDebounce: Timer?

    init(targets: TargetStore, scripts: ScriptStore, facts: FactStore,
         onOpenSettings: @escaping (SettingsSection) -> Void,
         onChanged: @escaping () -> Void) {
        self.targets = targets
        self.scripts = scripts
        self.facts = facts
        self.onOpenSettings = onOpenSettings
        self.onChanged = onChanged
        super.init(frame: .zero)
        rebuild()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func reloadForSelection() {
        guard !importing else { return }
        rebuild()
    }

    // MARK: - Build

    private func rebuild() {
        let w = self.w
        var rows: [NSView] = []
        let target = currentTarget?()

        if let target {
            rows.append(contentsOf: targetHeaderRows(target))
        } else {
            rows.append(SKBuild.pageTitle(w.globalAmmo))
            rows.append(SKBuild.divider())
        }

        // 装填弹药：统一入口（简历或面试稿），状态行原地反馈三段式。
        let loadBtn = SKButton(w.loadAmmo, systemImage: "tray.and.arrow.down", kind: .secondary) { [weak self] in
            self?.importAmmo()
        }
        let status = SKText.label("", font: SK.font(11, .medium), color: SK.accentHi)
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusLine = status
        rows.append(SKBuild.padded(SKBuild.help(w.ammoIntro, color: SK.secondary, size: 12), top: 14, bottom: 8))
        let loadRow = NSStackView(views: [loadBtn, SKBuild.spacer()])
        loadRow.orientation = .horizontal
        loadRow.alignment = .centerY
        rows.append(SKBuild.padded(loadRow, top: 0, bottom: 6))
        rows.append(SKBuild.padded(status, top: 0, bottom: 4))
        // 代价在按钮旁按下前写明（计量诚实——只有受管密钥才收）。
        if CreditPolicy.sessionIsMetered() {
            rows.append(SKBuild.padded(SKBuild.help(w.chargeNote), top: 0, bottom: 10))
        }
        rows.append(SKBuild.divider())

        rows.append(contentsOf: ammoRows(target: target))

        scroll.setRows(rows)
        revealNewCards()
    }

    // MARK: - Target header（公司/岗位/阶段/JD/用稿）

    private func targetHeaderRows(_ target: InterviewTarget) -> [NSView] {
        let w = self.w
        var rows: [NSView] = []

        let company = SKField(placeholder: w.companyPlaceholder)
        company.stringValue = target.company
        company.onChange = { [weak self] v in self?.debouncedUpdate { $0.update(id: target.id, company: v) } }
        let role = SKField(placeholder: w.rolePlaceholder)
        role.stringValue = target.role ?? ""
        role.onChange = { [weak self] v in self?.debouncedUpdate { $0.update(id: target.id, role: .some(v)) } }
        let stage = SKField(placeholder: w.stagePlaceholder)
        stage.stringValue = target.stage ?? ""
        stage.onChange = { [weak self] v in self?.debouncedUpdate { $0.update(id: target.id, stage: .some(v)) } }
        // 中栏可用列宽约 408pt（窗口 1000 − 两侧栏 − 内边距）：三个字段合计不得超列。
        [company, role, stage].forEach { $0.translatesAutoresizingMaskIntoConstraints = false }
        company.widthAnchor.constraint(equalToConstant: 168).isActive = true
        role.widthAnchor.constraint(equalToConstant: 118).isActive = true
        stage.widthAnchor.constraint(equalToConstant: 100).isActive = true
        let fieldRow = NSStackView(views: [company, role, stage, SKBuild.spacer()])
        fieldRow.orientation = .horizontal
        fieldRow.alignment = .centerY
        fieldRow.spacing = 8
        rows.append(SKBuild.padded(fieldRow, top: 0, bottom: 10))

        // 本目标用稿：绑定即换 armed 用稿（一司一稿）。
        var items = [SKPopup.Item(id: "", title: w.scriptNone)]
        items += scripts.all.map {
            SKPopup.Item(id: $0.id, title: "\($0.displayLabel) · \(w.scriptEntryCount($0.entries.count))")
        }
        let popup = SKPopup(items: items, selectedID: target.scriptID ?? "") { [weak self] id in
            self?.targets.update(id: target.id, scriptID: .some(id.isEmpty ? nil : id))
            self?.onChanged()
        }
        rows.append(SKBuild.controlRow(w.scriptBinding, control: popup, vPad: 10))

        // JD：v1 只留字段（热词 + identity 注入），明说不做深度分析。
        let jd = SKTextWell(monospaced: false)
        jd.string = target.jobDescription ?? ""
        jd.onChange = { [weak self] v in
            self?.debouncedUpdate { $0.update(id: target.id, jobDescription: .some(v)) }
        }
        jd.translatesAutoresizingMaskIntoConstraints = false
        jd.heightAnchor.constraint(equalToConstant: 64).isActive = true
        rows.append(SKBuild.stackedControl(w.jdLabel, control: jd, help: w.jdHelp, vPad: 8))
        rows.append(SKBuild.divider())
        return rows
    }

    /// 字段编辑的落盘去抖：每停顿 0.6s 存一次，而不是每个键一次磁盘写。
    private func debouncedUpdate(_ apply: @escaping (TargetStore) -> Bool) {
        fieldDebounce?.invalidate()
        fieldDebounce = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { [weak self] _ in
            guard let self else { return }
            _ = apply(self.targets)
            self.onChanged()
        }
    }

    // MARK: - Ammo cards

    private func ammoRows(target: InterviewTarget?) -> [NSView] {
        let w = self.w
        let sheet = facts.sheet
        var rows: [NSView] = []

        if sheet.experiences.isEmpty && sheet.motivations.isEmpty && sheet.notes.isEmpty {
            rows.append(SKBuild.padded(SKBuild.help(w.emptyAmmo, color: SK.secondary, size: 12.5),
                                       top: 18, bottom: 8))
            let editBtn = SKButton(w.editInSettings, systemImage: "square.and.pencil", kind: .plain) { [weak self] in
                self?.onOpenSettings(.facts)
            }
            rows.append(SKBuild.padded(SKBuild.cluster([editBtn]), top: 0, bottom: 16))
            return rows
        }

        func header(_ text: String) -> NSView {
            SKBuild.padded(SKText.label(text, font: SK.font(13, .semibold), color: SK.ink),
                           top: 16, bottom: 8)
        }

        if !sheet.experiences.isEmpty {
            rows.append(header(w.experiencesHeader))
            for exp in sheet.experiences {
                rows.append(card(for: .experience(exp), target: target))
            }
        }
        if !sheet.motivations.isEmpty {
            rows.append(header(w.motivationsHeader))
            for mot in sheet.motivations {
                rows.append(card(for: .motivation(mot), target: target))
            }
        }
        if !sheet.notes.isEmpty {
            rows.append(header(w.notesHeader))
            for note in sheet.notes {
                let label = SKText.label("· \(note)", font: SK.font(12), color: SK.secondary)
                rows.append(SKBuild.padded(label, top: 2, bottom: 2))
            }
        }
        let editBtn = SKButton(w.editInSettings, systemImage: "square.and.pencil", kind: .plain) { [weak self] in
            self?.onOpenSettings(.facts)
        }
        rows.append(SKBuild.padded(SKBuild.cluster([editBtn]), top: 12, bottom: 18))
        return rows
    }

    enum AmmoFact {
        case experience(Experience)
        case motivation(Motivation)

        var id: String {
            switch self {
            case .experience(let e): return e.id
            case .motivation(let m): return m.id
            }
        }
        var locked: Bool {
            switch self {
            case .experience(let e): return e.locked == true
            case .motivation(let m): return m.locked == true
            }
        }
        var provenance: Provenance? {
            switch self {
            case .experience(let e): return e.provenance
            case .motivation(let m): return m.provenance
            }
        }
        /// 低置信 = 有出处但引用对不上原文（imported 且 quote 缺失）。手写事实无 provenance，
        /// 不算不确定。
        var uncertain: Bool { provenance != nil && provenance?.quote == nil && !locked }
    }

    private func card(for fact: AmmoFact, target: InterviewTarget?) -> NSView {
        let w = self.w
        let card = WBAmmoCard(fact: fact, strings: w, target: target)
        card.onToggleConfirm = { [weak self] in self?.toggleLocked(fact) }
        card.onDelete = { [weak self] in self?.deleteFact(fact) }
        card.onTogglePin = { [weak self] in self?.toggleEmphasis(fact, pin: true) }
        card.onToggleExclude = { [weak self] in self?.toggleEmphasis(fact, pin: false) }
        card.wantsLayer = true
        if revealIDs.contains(fact.id) { card.layer?.opacity = 0 }
        return SKBuild.padded(card, top: 4, bottom: 4)
    }

    /// 导入后新卡片的错峰浮现：150ms 间隔逐张实体化——「弹药入库」的视觉节律
    /// 与刘海逐字诞生同源（淡入 + 轻微上浮）。
    private func revealNewCards() {
        guard !revealIDs.isEmpty else { return }
        let ids = revealIDs
        revealIDs = []
        var delay: TimeInterval = 0.05
        for container in scroll.stack.arrangedSubviews {
            guard let card = container.subviews.first as? WBAmmoCard,
                  ids.contains(card.factID), let layer = card.layer else { continue }
            if SKMotion.reduced { layer.opacity = 1; continue }
            layer.opacity = 0
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 0; fade.toValue = 1
                fade.duration = 0.28
                fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
                let rise = CABasicAnimation(keyPath: "transform.translation.y")
                rise.fromValue = 6; rise.toValue = 0
                rise.duration = 0.28
                rise.timingFunction = CAMediaTimingFunction(name: .easeOut)
                layer.add(fade, forKey: "reveal")
                layer.add(rise, forKey: "rise")
                layer.opacity = 1
            }
            delay += 0.15
        }
    }

    // MARK: - Fact mutations

    private func toggleLocked(_ fact: AmmoFact) {
        var sheet = facts.sheet
        switch fact {
        case .experience(let e):
            guard let i = sheet.experiences.firstIndex(where: { $0.id == e.id }) else { return }
            sheet.experiences[i].locked = (e.locked == true) ? nil : true
        case .motivation(let m):
            guard let i = sheet.motivations.firstIndex(where: { $0.id == m.id }) else { return }
            sheet.motivations[i].locked = (m.locked == true) ? nil : true
        }
        commit(sheet)
    }

    private func deleteFact(_ fact: AmmoFact) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "\(w.deleteFact)?"
        alert.addButton(withTitle: AppStrings.current.deleteButton)
        alert.addButton(withTitle: AppStrings.current.cancel)
        guard let window else { return }
        alert.beginSheetModalGuarded(for: window) { [weak self] resp in
            guard resp == .alertFirstButtonReturn, let self else { return }
            var sheet = self.facts.sheet
            switch fact {
            case .experience(let e): sheet.experiences.removeAll { $0.id == e.id }
            case .motivation(let m): sheet.motivations.removeAll { $0.id == m.id }
            }
            self.commit(sheet)
        }
    }

    /// 一司一策的就地开关：置顶与排除互斥（同一条事实不可能既必带又不带）。
    private func toggleEmphasis(_ fact: AmmoFact, pin: Bool) {
        guard let target = currentTarget?() else { return }
        var e = target.emphasis ?? .empty
        var pinned = Set(e.pinnedFactIDs ?? [])
        var excluded = Set(e.excludedFactIDs ?? [])
        let id = fact.id
        if pin {
            if pinned.contains(id) { pinned.remove(id) } else { pinned.insert(id); excluded.remove(id) }
        } else {
            if excluded.contains(id) { excluded.remove(id) } else { excluded.insert(id); pinned.remove(id) }
        }
        e.pinnedFactIDs = pinned.isEmpty ? nil : Array(pinned).sorted()
        e.excludedFactIDs = excluded.isEmpty ? nil : Array(excluded).sorted()
        targets.update(id: target.id, emphasis: .some(e))
        rebuild()
        onChanged()
    }

    private func commit(_ sheet: FactSheet) {
        guard facts.save(sheet) else {
            // 保存失败绝不静默（同 FactsSection 的纪律）——状态行原地告警。
            setStatus(AppStrings.current.factsSaveFailed, color: SK.destructive)
            return
        }
        rebuild()
        onChanged()
    }

    // MARK: - Import（装填弹药）

    private func importAmmo() {
        let panel = NSOpenPanel()
        // 文件选择器列出的正是简历文件名——同门屏幕共享保护。
        ScreenShareGuard.exclude(panel)
        panel.allowedContentTypes = ResumeReaders.openPanelTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importFile(url)
    }

    /// 外部入口（引导结束的简历移交也走这里）：读取 → 分流 → 解析 → 反馈，全链在面板内。
    func importFile(_ url: URL) {
        importing = true
        let w = self.w
        let target = currentTarget?()
        Task { [weak self] in
            do {
                // 读取（可能含 OCR）走后台；一切 UI 反馈回主线程。
                let doc = try await Task.detached(priority: .userInitiated) {
                    try ResumeReaders.read(url: url)
                }.value
                await MainActor.run { self?.setStatus(w.parsingLocal(doc.blocks.count), color: SK.accentHi) }
                await self?.route(doc, target: target)
            } catch {
                await MainActor.run {
                    self?.importing = false
                    self?.setStatus(error.localizedDescription, color: SK.destructive)
                }
            }
        }
    }

    /// 统一入口的分流：简历专属标题 ≥2 → 简历；否则问答覆盖率好 → 面试稿；再否则简历。
    @MainActor
    private func route(_ doc: ResumeDocument, target: InterviewTarget?) async {
        let w = self.w
        let det = ScriptImporter.deterministic(doc.plainText)
        let isResume = ResumeExtractor.resumeSignalCount(doc.plainText) >= 2
        if !isResume, det.coverage >= ScriptImporter.goodCoverage, det.entries.count >= 2 {
            // 面试稿路径：入稿库并绑定当前目标。
            let name = (doc.sourceName as NSString).deletingPathExtension
            if let id = scripts.add(name: name, company: target?.company, entries: det.entries) {
                if let target { targets.update(id: target.id, scriptID: .some(id)) }
                importing = false
                rebuild()
                setStatus(w.parsedAsScript(det.entries.count), color: SK.accentHi)
                onChanged()
            } else {
                importing = false
                setStatus(AppStrings.current.scriptSaveFailedTitle, color: SK.destructive)
            }
            return
        }

        // 简历路径。三种离线终点各给诚实的原因：隐私门/未配置、额度不足、抽取失败。
        guard ResumeExtractor.isLLMAvailable else {
            importing = false
            rebuild()
            setStatus(w.parseLLMOff, color: SK.warning)
            return
        }
        if CreditPolicy.sessionIsMetered(),
           CreditManager.shared.balanceSeconds < ResumeExtractor.chargeSeconds {
            importing = false
            rebuild()
            setStatus(w.parseNoCredit, color: SK.warning)
            return
        }
        setStatus(w.parsingExtract, color: SK.accentHi)
        let result = await ResumeExtractor.extract(doc)
        importing = false
        guard result.usedLLM else {
            rebuild()
            setStatus(w.extractFailed, color: SK.warning)
            return
        }
        let merged = Self.merge(result.sheet, into: facts.sheet)
        revealIDs = merged.newIDs
        guard facts.save(merged.sheet) else {
            setStatus(AppStrings.current.factsSaveFailed, color: SK.destructive)
            return
        }
        rebuild()
        setStatus(w.extracted(result.sheet.experiences.count, result.sheet.motivations.count,
                              result.sheet.notes.count, uncertain: result.uncertainCount),
                  color: SK.accentHi)
        onChanged()
    }

    /// 抽取结果并入既有事实表：追加而非替换（既有的手写事实一个都不能动），
    /// id 冲突时重命名（二次导入不覆盖第一次）。
    static func merge(_ incoming: FactSheet, into existing: FactSheet)
        -> (sheet: FactSheet, newIDs: Set<String>) {
        var sheet = existing
        var newIDs: Set<String> = []
        var usedExp = Set(existing.experiences.map(\.id))
        for var e in incoming.experiences {
            while usedExp.contains(e.id) { e.id += "x" }
            usedExp.insert(e.id)
            newIDs.insert(e.id)
            sheet.experiences.append(e)
        }
        var usedMot = Set(existing.motivations.map(\.id))
        for var m in incoming.motivations {
            while usedMot.contains(m.id) { m.id += "x" }
            usedMot.insert(m.id)
            newIDs.insert(m.id)
            sheet.motivations.append(m)
        }
        if sheet.profile == nil { sheet.profile = incoming.profile }
        let existingNotes = Set(existing.notes)
        sheet.notes += incoming.notes.filter { !existingNotes.contains($0) }
        return (sheet, newIDs)
    }

    private func setStatus(_ text: String, color: NSColor) {
        statusLine?.attributedStringValue = SKText.attributed(
            text, font: SK.font(11, .medium), color: color)
    }
}

// MARK: - Card

/// 一张弹药卡：标题 + 要点 + 出处引用 + 状态徽章 + 操作行。
/// 草稿 = 虚线边框；已确认 = 实线 + ✓；低置信 = 琥珀虚线 + 「AI 不确定」。
final class WBAmmoCard: FlippedView {
    let factID: String
    private let fact: WBAmmoPanel.AmmoFact
    private let strings: WBStrings
    private let target: InterviewTarget?

    var onToggleConfirm: (() -> Void)?
    var onDelete: (() -> Void)?
    var onTogglePin: (() -> Void)?
    var onToggleExclude: (() -> Void)?

    init(fact: WBAmmoPanel.AmmoFact, strings: WBStrings, target: InterviewTarget?) {
        self.fact = fact
        self.factID = fact.id
        self.strings = strings
        self.target = target
        super.init(frame: .zero)
        build()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var isPinned: Bool {
        target?.emphasis?.pinnedFactIDs?.contains(fact.id) == true
    }
    private var isExcluded: Bool {
        target?.emphasis?.excludedFactIDs?.contains(fact.id) == true
    }

    private func build() {
        let w = strings
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])

        let (title, detail) = content()
        let titleColor: NSColor = isExcluded ? SK.tertiary : SK.ink
        let titleRow = NSStackView(views: [
            SKText.label(title, font: SK.font(13, .semibold), color: titleColor),
            SKBuild.spacer(min: 8),
            badge(),
        ])
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(titleRow)
        titleRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        if !detail.isEmpty {
            let d = SKText.label(detail, font: SK.font(11.5), color: isExcluded ? SK.tertiary : SK.secondary,
                                 lineSpacing: 2)
            d.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(d)
            d.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        // 出处引用：用户亲眼看见 AI 读到了哪一行——不需要「相信」。
        if let p = fact.provenance {
            if let quote = p.quote {
                let src = SKText.label("\(w.sourceFrom(p.source ?? ""))：“\(quote)”",
                                       font: SK.font(10.5), color: SK.tertiary, lineSpacing: 2)
                src.translatesAutoresizingMaskIntoConstraints = false
                stack.addArrangedSubview(src)
                src.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            } else if !fact.locked {
                let warn = SKText.label(w.uncertainBadge, font: SK.font(10.5, .medium), color: SK.warning)
                stack.addArrangedSubview(warn)
            }
        }

        var actions: [NSView] = [
            SKButton(fact.locked ? w.confirmed : w.confirm,
                     systemImage: fact.locked ? "checkmark.circle.fill" : "checkmark.circle",
                     kind: .plain) { [weak self] in self?.onToggleConfirm?() },
        ]
        if target != nil {
            actions.append(SKButton(w.pinForTarget,
                                    systemImage: isPinned ? "pin.fill" : "pin",
                                    kind: .plain) { [weak self] in self?.onTogglePin?() })
            actions.append(SKButton(w.excludeForTarget,
                                    systemImage: isExcluded ? "eye.slash.fill" : "eye.slash",
                                    kind: .plain) { [weak self] in self?.onToggleExclude?() })
        }
        actions.append(SKButton(w.deleteFact, systemImage: "trash", kind: .plain) { [weak self] in
            self?.onDelete?()
        })
        let actionRow = SKBuild.cluster(actions, spacing: 2)
        stack.setCustomSpacing(9, after: stack.arrangedSubviews.last!)
        stack.addArrangedSubview(actionRow)
    }

    private func content() -> (title: String, detail: String) {
        switch fact {
        case .experience(let e):
            var title = [e.role, e.org].filter { !$0.isEmpty }.joined(separator: " @ ")
            if !e.period.isEmpty { title += "（\(e.period)）" }
            var lines: [String] = []
            if !e.actions.isEmpty { lines.append(e.actions.joined(separator: "、")) }
            if !e.results.isEmpty { lines.append(e.results.joined(separator: "、")) }
            if !e.skills.isEmpty { lines.append(e.skills.joined(separator: " · ")) }
            return (title, lines.joined(separator: "\n"))
        case .motivation(let m):
            var title = m.statement
            if let c = m.targetCompany, !c.isEmpty { title = "[\(c)] " + title }
            return (title, m.careerAxis ?? "")
        }
    }

    private func badge() -> NSView {
        let w = strings
        let text: String
        let color: NSColor
        if isExcluded {
            text = w.excludeForTarget; color = SK.tertiary
        } else if fact.locked {
            text = w.confirmed; color = SK.accentHi
        } else if fact.uncertain {
            text = w.draft; color = SK.warning
        } else {
            text = w.draft; color = SK.secondary
        }
        let label = SKText.label(text, font: SK.font(10, .semibold), color: color)
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        return label
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let b = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = CGPath(roundedRect: b, cornerWidth: 10, cornerHeight: 10, transform: nil)
        // 卡面：确认态更沉稳，草稿更「未完成」。
        ctx.addPath(path)
        ctx.setFillColor(SK.ink(fact.locked ? 0.055 : 0.03).cgColor)
        ctx.fillPath()
        ctx.addPath(path)
        let stroke: NSColor = isExcluded ? SK.ink(0.10)
            : fact.locked ? SK.ink(0.16)
            : fact.uncertain ? SK.warning.withAlphaComponent(0.55)
            : SK.ink(0.14)
        ctx.setStrokeColor(stroke.cgColor)
        ctx.setLineWidth(1)
        if !fact.locked {
            ctx.setLineDash(phase: 0, lengths: [4, 3])   // 草稿 = 虚线（未完成的视觉语言）
        }
        ctx.strokePath()
    }
}
