import AppKit
import Combine
import UniformTypeIdentifiers

// The interview-script library — list ↔ editor, inline rename, hover-revealed row actions,
// file import. Observes the live `ScriptStore` so edits elsewhere reflect immediately.

final class ScriptsSection: FlippedView {
    private let store: ScriptStore
    private var cancellable: AnyCancellable?

    private let stage = FlippedView()
    private var listView: NSView?
    private var editorView: NSView?
    private var editing = false
    private var renamingID: String?

    private var s: AppStrings { AppStrings(language: AppLanguageStore.shared.language) }

    init(store: ScriptStore) {
        self.store = store
        super.init(frame: .zero)
        stage.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stage)
        NSLayoutConstraint.activate([
            stage.leadingAnchor.constraint(equalTo: leadingAnchor),
            stage.trailingAnchor.constraint(equalTo: trailingAnchor),
            stage.topAnchor.constraint(equalTo: topAnchor),
            stage.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        showList(animated: false)
        cancellable = store.$library
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in guard let self, !self.editing else { return }; self.rebuildList() }

        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--qa-editor") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard let self else { return }
                if let id = store.activeID { self.showEditor(.existing(id: id)) }
                else { self.showEditor(.new(name: "", text: "")) }
            }
        }
        #endif
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: List

    private func buildList() -> NSView {
        let s = self.s
        let scroll = SKScroll()

        let importBtn = SKButton(s.addByFile, systemImage: "square.and.arrow.down", kind: .secondary) { [weak self] in
            self?.importFromFile()
        }
        let addBtn = SKButton(s.addByPaste, systemImage: "plus", kind: .primary) { [weak self] in
            self?.showEditor(.new(name: "", text: ""))
        }
        let header = SKBuild.row(SKBuild.pageTitle(s.secScripts), SKBuild.cluster([importBtn, addBtn]), vPad: 0)

        var rows: [NSView] = [header, SKBuild.divider()]
        if store.all.isEmpty {
            rows.append(emptyState())
        } else {
            for script in store.all {
                rows.append(makeRow(script))
                rows.append(SKBuild.divider())
            }
        }
        scroll.setRows(rows)
        scroll.gap(18, after: header)
        return scroll
    }

    private func makeRow(_ script: InterviewScript) -> NSView {
        let row = ScriptRowView(
            script: script,
            active: store.activeID == script.id,
            renaming: renamingID == script.id,
            dateText: dateString(script.updatedAt),
            onSetActive: { [weak self] in self?.store.setActive(script.id) },
            onEdit: { [weak self] in self?.showEditor(.existing(id: script.id)) },
            onRename: { [weak self] in self?.renamingID = script.id; self?.rebuildList() },
            onCommitRename: { [weak self] newName in
                self?.store.update(id: script.id, name: newName)
                self?.renamingID = nil
            },
            onCancelRename: { [weak self] in self?.renamingID = nil; self?.rebuildList() },
            onDelete: { [weak self] in self?.confirmDelete(script) }
        )
        return row
    }

    private func emptyState() -> NSView {
        let s = self.s
        let c = FlippedView()
        let icon = NSImageView()
        let cfg = NSImage.SymbolConfiguration(pointSize: 30, weight: .light)
        icon.image = NSImage(systemSymbolName: "doc.text", accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
        icon.contentTintColor = SK.tertiary
        let title = SKText.label(s.scriptsEmptyTitle, font: SK.font(15, .semibold), color: SK.ink, align: .center)
        let hint = SKText.label(s.scriptsEmptyHint, font: SK.font(12), color: SK.secondary, align: .center, lineSpacing: 2.5)
        let stack = NSStackView(views: [icon, title, hint])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        c.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: c.centerXAnchor),
            stack.topAnchor.constraint(equalTo: c.topAnchor, constant: 64),
            stack.bottomAnchor.constraint(equalTo: c.bottomAnchor, constant: -40),
            hint.widthAnchor.constraint(lessThanOrEqualToConstant: 430),
        ])
        return c
    }

    // MARK: Editor

    enum EditTarget {
        case new(name: String, text: String)
        case existing(id: String)
    }

    private func showEditor(_ target: EditTarget) {
        editing = true
        let editor: ScriptEditorView
        switch target {
        case .new(let name, let text):
            editor = ScriptEditorView(title: s.newScriptTitle, name: name, text: text,
                                      onCancel: { [weak self] in self?.showList(animated: true); self?.editing = false },
                                      onSave: { [weak self] newName, entries in
                                          guard let self else { return }
                                          self.store.add(name: self.resolvedName(newName, entries: entries), entries: entries)
                                          self.editing = false
                                          self.showList(animated: true)
                                      })
        case .existing(let id):
            let script = store.all.first { $0.id == id }
            editor = ScriptEditorView(title: script?.name ?? s.editScript,
                                      name: script?.name ?? "",
                                      text: store.conventionText(for: id),
                                      onCancel: { [weak self] in self?.showList(animated: true); self?.editing = false },
                                      onSave: { [weak self] newName, entries in
                                          guard let self else { return }
                                          self.store.update(id: id, name: newName, entries: entries)
                                          self.editing = false
                                          self.showList(animated: true)
                                      })
        }
        crossfade(to: editor)
        listView = nil
        editorView = editor
    }

    // MARK: Transitions

    private func showList(animated: Bool) {
        let list = buildList()
        if animated { crossfade(to: list) } else { mount(list); listView = list }
        listView = list
        editorView = nil
    }

    private func rebuildList() {
        guard !editing else { return }
        let list = buildList()
        mount(list)
        // swap instantly (state change, not navigation)
        listView?.removeFromSuperview()
        editorView?.removeFromSuperview(); editorView = nil
        listView = list
    }

    private func mount(_ view: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        stage.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: stage.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: stage.trailingAnchor),
            view.topAnchor.constraint(equalTo: stage.topAnchor),
            view.bottomAnchor.constraint(equalTo: stage.bottomAnchor),
        ])
    }

    private func crossfade(to newView: NSView) {
        let old = stage.subviews
        mount(newView)
        newView.wantsLayer = true
        if SKMotion.reduced {
            old.forEach { $0.removeFromSuperview() }
            return
        }
        newView.alphaValue = 0
        newView.layer?.transform = CATransform3DMakeTranslation(8, 0, 0)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.26
            ctx.allowsImplicitAnimation = true
            newView.animator().alphaValue = 1
            newView.layer?.transform = CATransform3DIdentity
            old.forEach { $0.animator().alphaValue = 0 }
        } completionHandler: {
            old.forEach { $0.removeFromSuperview() }
        }
    }

    // MARK: Actions

    private func resolvedName(_ typed: String, entries: [BankEntry]) -> String {
        let name = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? (entries.first?.question ?? "") : name
    }

    private func confirmDelete(_ script: InterviewScript) {
        let s = self.s
        let alert = NSAlert()
        alert.messageText = s.deleteScriptConfirmTitle(script.name)
        alert.informativeText = s.deleteScriptConfirmBody
        alert.alertStyle = .warning
        alert.addButton(withTitle: s.deleteButton)
        alert.addButton(withTitle: s.cancel)
        guard let window else { return }
        alert.beginSheetModal(for: window) { [weak self] resp in
            if resp == .alertFirstButtonReturn { self?.store.remove(id: script.id) }
        }
    }

    private func importFromFile() {
        let panel = NSOpenPanel()
        var types: [UTType] = [.plainText, .text]
        if let md = UTType(filenameExtension: "md") { types.append(md) }
        if let md = UTType(filenameExtension: "markdown") { types.append(md) }
        panel.allowedContentTypes = types
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url,
           let content = try? String(contentsOf: url, encoding: .utf8) {
            showEditor(.new(name: url.deletingPathExtension().lastPathComponent, text: content))
        }
    }

    private func dateString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        f.locale = Locale(identifier: AppLanguageStore.shared.language == .zh ? "zh_CN" : "ja_JP")
        return f.string(from: date)
    }
}

// MARK: - Script row

final class ScriptRowView: FlippedView {
    private let script: InterviewScript
    private let active: Bool
    private let renaming: Bool
    private let dateText: String
    private let onSetActive: () -> Void
    private let onEdit: () -> Void
    private let onRename: () -> Void
    private let onCommitRename: (String) -> Void
    private let onCancelRename: () -> Void
    private let onDelete: () -> Void

    private var hovering = false { didSet { if hovering != oldValue { reflectHover() } } }
    private var tracking: NSTrackingArea?
    private var actions: NSView?
    private var renameField: SKField?

    private var s: AppStrings { AppStrings(language: AppLanguageStore.shared.language) }

    init(script: InterviewScript, active: Bool, renaming: Bool, dateText: String,
         onSetActive: @escaping () -> Void, onEdit: @escaping () -> Void,
         onRename: @escaping () -> Void, onCommitRename: @escaping (String) -> Void,
         onCancelRename: @escaping () -> Void, onDelete: @escaping () -> Void) {
        self.script = script; self.active = active; self.renaming = renaming; self.dateText = dateText
        self.onSetActive = onSetActive; self.onEdit = onEdit; self.onRename = onRename
        self.onCommitRename = onCommitRename; self.onCancelRename = onCancelRename; self.onDelete = onDelete
        super.init(frame: .zero)
        build()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t); tracking = t
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    private func build() {
        let s = self.s

        // Left column: name (or rename field) + meta.
        let nameLine: NSView
        if renaming {
            let f = SKField(placeholder: s.scriptNamePlaceholder)
            f.stringValue = script.name
            f.onSubmit = { [weak self] in self?.onCommitRename(f.stringValue) }
            f.translatesAutoresizingMaskIntoConstraints = false
            f.widthAnchor.constraint(equalToConstant: 260).isActive = true
            f.heightAnchor.constraint(equalToConstant: 30).isActive = true
            renameField = f
            nameLine = f
        } else {
            let name = SKText.label(script.name, font: SK.font(14, .semibold), color: SK.ink)
            name.translatesAutoresizingMaskIntoConstraints = false
            if active {
                let badge = ActiveBadge(text: s.activeBadge)
                let line = NSStackView(views: [name, badge])
                line.orientation = .horizontal; line.alignment = .centerY; line.spacing = 8
                nameLine = line
            } else {
                nameLine = name
            }
        }

        let meta = SKText.label("\(s.scriptCount(script.entries.count)) · \(s.scriptUpdated(dateText))",
                                font: SK.font(11), color: SK.tertiary)
        let leftCol = NSStackView(views: [nameLine, meta])
        leftCol.orientation = .vertical
        leftCol.alignment = .leading
        leftCol.spacing = 5
        leftCol.translatesAutoresizingMaskIntoConstraints = false
        leftCol.setContentHuggingPriority(.defaultLow, for: .horizontal)
        addSubview(leftCol)

        // Right column: action buttons, revealed on hover.
        var buttons: [NSView] = []
        if !active { buttons.append(SKButton(s.setActiveScript, kind: .plain, action: onSetActive)) }
        buttons.append(SKButton(s.editScript, systemImage: "pencil", kind: .plain, action: onEdit))
        buttons.append(SKButton(s.renameScript, kind: .plain, action: onRename))
        buttons.append(SKButton(s.deleteButton, systemImage: "trash", kind: .plain, tint: SK.destructive, action: onDelete))
        let actionRow = NSStackView(views: buttons)
        actionRow.orientation = .horizontal
        actionRow.alignment = .centerY
        actionRow.spacing = 2
        actionRow.translatesAutoresizingMaskIntoConstraints = false
        actionRow.setContentHuggingPriority(.required, for: .horizontal)
        actionRow.alphaValue = (renaming || hovering) ? 1 : 0
        actions = actionRow
        addSubview(actionRow)

        NSLayoutConstraint.activate([
            leftCol.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            leftCol.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            leftCol.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
            actionRow.centerYAnchor.constraint(equalTo: leftCol.centerYAnchor),
            actionRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            actionRow.leadingAnchor.constraint(greaterThanOrEqualTo: leftCol.trailingAnchor, constant: 12),
        ])

        if renaming {
            DispatchQueue.main.async { [weak self] in self?.renameField?.focus() }
        }
    }

    private func reflectHover() {
        needsDisplay = true
        guard let actions, !renaming else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            ctx.allowsImplicitAnimation = true
            actions.animator().alphaValue = hovering ? 1 : 0
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard hovering else { return }
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let path = CGPath(roundedRect: bounds.insetBy(dx: 2, dy: 3), cornerWidth: 9, cornerHeight: 9, transform: nil)
        ctx.addPath(path); ctx.setFillColor(SK.ink(0.04).cgColor); ctx.fillPath()
    }
}

/// The "active" capsule badge.
final class ActiveBadge: NSView {
    private let text: String
    init(text: String) {
        self.text = text
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize {
        let s = SKText.attributed(text, font: SK.font(9.5, .semibold), color: .white).size()
        return NSSize(width: ceil(s.width) + 14, height: 17)
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let path = CGPath(roundedRect: bounds, cornerWidth: bounds.height / 2, cornerHeight: bounds.height / 2, transform: nil)
        ctx.addPath(path); ctx.setFillColor(SK.accent.withAlphaComponent(0.14).cgColor); ctx.fillPath()
        let attr = SKText.attributed(text, font: SK.font(9.5, .semibold), color: SK.accentHi, tracking: 0.3)
        let sz = attr.size()
        attr.draw(at: CGPoint(x: (bounds.width - sz.width) / 2, y: bounds.midY - sz.height / 2))
    }
}

// MARK: - Editor

final class ScriptEditorView: FlippedView {
    private let onCancel: () -> Void
    private let onSave: (String, [BankEntry]) -> Void

    private var nameField: SKField!
    private var well: SKTextWell!
    private var preview: NSTextField!
    private var saveBtn: SKButton!

    private var s: AppStrings { AppStrings(language: AppLanguageStore.shared.language) }

    init(title: String, name: String, text: String,
         onCancel: @escaping () -> Void, onSave: @escaping (String, [BankEntry]) -> Void) {
        self.onCancel = onCancel
        self.onSave = onSave
        super.init(frame: .zero)
        build(title: title, name: name, text: text)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func build(title: String, name: String, text: String) {
        let s = self.s
        let backBtn = SKButton(s.back, systemImage: "chevron.left", kind: .plain, action: onCancel)
        let titleLabel = SKBuild.pageTitle(title)
        titleLabel.maximumNumberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        saveBtn = SKButton(s.saveWithShortcut, kind: .primary) { [weak self] in self?.commit() }
        let header = SKBuild.cluster([backBtn, titleLabel], spacing: 8)
        let headerRow = NSStackView(views: [header, SKBuild.spacer(), saveBtn])
        headerRow.orientation = .horizontal; headerRow.alignment = .centerY; headerRow.spacing = 12
        headerRow.translatesAutoresizingMaskIntoConstraints = false

        nameField = SKField(placeholder: s.scriptNamePlaceholder)
        nameField.stringValue = name
        nameField.translatesAutoresizingMaskIntoConstraints = false

        let desc = SKBuild.help(s.prepDescription, color: SK.secondary, size: 11.5)
        desc.translatesAutoresizingMaskIntoConstraints = false

        preview = SKText.label("", font: SK.font(11, .medium), color: SK.tertiary)
        preview.translatesAutoresizingMaskIntoConstraints = false
        preview.maximumNumberOfLines = 2

        well = SKTextWell(monospaced: true)
        well.string = text
        well.translatesAutoresizingMaskIntoConstraints = false
        well.onChange = { [weak self] _ in self?.refreshPreview() }

        [headerRow, nameField, desc, preview, well].forEach { addSubview($0) }
        let inset: CGFloat = 32
        NSLayoutConstraint.activate([
            headerRow.topAnchor.constraint(equalTo: topAnchor, constant: 24),
            headerRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            headerRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),

            nameField.topAnchor.constraint(equalTo: headerRow.bottomAnchor, constant: 18),
            nameField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            nameField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            nameField.heightAnchor.constraint(equalToConstant: 34),

            desc.topAnchor.constraint(equalTo: nameField.bottomAnchor, constant: 12),
            desc.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            desc.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),

            preview.topAnchor.constraint(equalTo: desc.bottomAnchor, constant: 10),
            preview.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            preview.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),

            well.topAnchor.constraint(equalTo: preview.bottomAnchor, constant: 10),
            well.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            well.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            well.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -28),
        ])
        refreshPreview()
    }

    private var parsed: [BankEntry] { ScriptParser.parse(well.string) }

    private func refreshPreview() {
        let p = parsed
        let names = p.prefix(6).map(\.question).joined(separator: " / ")
        let line = s.prepRecognition(count: p.count, names: names, hasMore: p.count > 6)
        preview.attributedStringValue = SKText.attributed(line, font: SK.font(11, .medium),
                                                          color: p.isEmpty ? SK.tertiary : SK.accentHi)
        saveBtn.isEnabledFlag = !p.isEmpty
    }

    private func commit() {
        let p = parsed
        guard !p.isEmpty else { return }
        onSave(nameField.stringValue, p)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "s" {
            commit()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
