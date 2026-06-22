import AppKit

// The five scrolling sections. Each binds to exactly the same data layer the SwiftUI build
// did (Keychain via `Secrets`, `Settings`, `AppLanguageStore`) — only the presentation is
// new. Language changes rebuild the live section from the root, so sections read copy once.

// MARK: - Base

class SectionScroll: FlippedView {
    let scroll = SKScroll()
    var s: AppStrings { AppStrings(language: AppLanguageStore.shared.language) }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

// MARK: - General

final class GeneralSection: SectionScroll {
    init() {
        super.init(frame: .zero)
        let s = self.s
        let seg = SKSegmented(titles: [s.chinese, s.japanese],
                              selected: AppLanguageStore.shared.language == .zh ? 0 : 1) { idx in
            AppLanguageStore.shared.language = (idx == 0) ? .zh : .ja
        }
        constrain(seg, width: 204, height: 30)

        let title = SKBuild.pageTitle(s.uiLanguageSettings)
        scroll.setRows([
            title,
            SKBuild.divider(),
            SKBuild.controlRow(s.uiLanguageSettings, control: seg, help: s.languageSummaryValue),
            SKBuild.divider(),
        ])
        scroll.gap(18, after: title)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

// MARK: - API keys

final class KeysSection: SectionScroll {
    init(onKeysChanged: @escaping () -> Void) {
        super.init(frame: .zero)
        let s = self.s
        let title = SKBuild.pageTitle(s.apiKeySettings)
        let help = SKBuild.help(s.apiKeyPrompt)
        scroll.setRows([
            title,
            SKBuild.divider(),
            KeyRowView(label: s.speechRecognitionProvider, name: "DEEPGRAM_API_KEY", onChanged: onKeysChanged),
            SKBuild.divider(),
            KeyRowView(label: "Gemini", name: "GEMINI_API_KEY", onChanged: onKeysChanged),
            SKBuild.divider(),
            KeyRowView(label: "Anthropic (Claude)", name: "ANTHROPIC_API_KEY", onChanged: onKeysChanged),
            SKBuild.divider(),
            help,
        ])
        scroll.gap(18, after: title)
        scroll.gap(16, after: scroll.stack.arrangedSubviews[scroll.stack.arrangedSubviews.count - 2])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// One key: a status glyph, a secure monospaced well, save + (when set) clear.
final class KeyRowView: FlippedView {
    private let label: String
    private let name: String
    private let onChanged: () -> Void

    private let status = NSImageView()
    private var field: SKField!
    private var saveBtn: SKButton!
    private var clearBtn: SKButton!
    private let buttonRow = NSStackView()
    private var isSet = false

    init(label: String, name: String, onChanged: @escaping () -> Void) {
        self.label = label
        self.name = name
        self.onChanged = onChanged
        super.init(frame: .zero)
        build()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var s: AppStrings { AppStrings(language: AppLanguageStore.shared.language) }

    private func build() {
        let s = self.s
        let current = Secrets.get(name) ?? ""
        isSet = !current.isEmpty

        status.wantsLayer = true
        status.imageScaling = .scaleProportionallyUpOrDown
        status.translatesAutoresizingMaskIntoConstraints = false
        status.setContentHuggingPriority(.required, for: .horizontal)

        let labelField = SKText.label(label, font: SK.font(14, .semibold), color: SK.ink)
        labelField.translatesAutoresizingMaskIntoConstraints = false
        labelField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let titleLine = NSStackView(views: [status, labelField])
        titleLine.orientation = .horizontal
        titleLine.alignment = .centerY
        titleLine.spacing = 8
        titleLine.translatesAutoresizingMaskIntoConstraints = false

        field = SKField(placeholder: s.apiKeyTitle(label), secure: true, monospaced: true)
        field.stringValue = current
        field.translatesAutoresizingMaskIntoConstraints = false
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.onSubmit = { [weak self] in self?.save() }

        saveBtn = SKButton(s.save, kind: .secondary) { [weak self] in self?.save() }
        saveBtn.minWidth = 56
        clearBtn = SKButton(s.clearKey, kind: .plain) { [weak self] in self?.clear() }
        clearBtn.translatesAutoresizingMaskIntoConstraints = false

        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.spacing = 2
        buttonRow.translatesAutoresizingMaskIntoConstraints = false
        buttonRow.setContentHuggingPriority(.required, for: .horizontal)

        let fieldLine = NSStackView(views: [field, buttonRow])
        fieldLine.orientation = .horizontal
        fieldLine.alignment = .centerY
        fieldLine.spacing = 8
        fieldLine.translatesAutoresizingMaskIntoConstraints = false

        addSubview(titleLine); addSubview(fieldLine)
        NSLayoutConstraint.activate([
            status.widthAnchor.constraint(equalToConstant: 16),
            status.heightAnchor.constraint(equalToConstant: 16),
            field.heightAnchor.constraint(equalToConstant: 34),
            titleLine.topAnchor.constraint(equalTo: topAnchor, constant: 17),
            titleLine.leadingAnchor.constraint(equalTo: leadingAnchor),
            titleLine.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            fieldLine.topAnchor.constraint(equalTo: titleLine.bottomAnchor, constant: 10),
            fieldLine.leadingAnchor.constraint(equalTo: leadingAnchor),
            fieldLine.trailingAnchor.constraint(equalTo: trailingAnchor),
            fieldLine.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -17),
        ])
        refreshStatus(bounce: false)
        refreshButtons()
    }

    private func refreshStatus(bounce: Bool) {
        let name = isSet ? "checkmark.circle.fill" : "circle"
        let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        img?.isTemplate = true
        status.image = img
        status.contentTintColor = isSet ? SK.accent : SK.tertiary
        if bounce, isSet { status.addSymbolEffect(.bounce, options: .nonRepeating) }
    }

    private func refreshButtons() {
        buttonRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        buttonRow.addArrangedSubview(saveBtn)
        if isSet { buttonRow.addArrangedSubview(clearBtn) }
    }

    private func save() {
        let trimmed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { Secrets.delete(name) } else { Secrets.set(name, trimmed) }
        let was = isSet
        isSet = !trimmed.isEmpty
        refreshStatus(bounce: isSet && !was)
        refreshButtons()
        onChanged()
    }

    private func clear() {
        field.stringValue = ""
        Secrets.delete(name)
        isSet = false
        refreshStatus(bounce: false)
        refreshButtons()
        onChanged()
    }
}

// MARK: - Answer engine

final class AnswerSection: SectionScroll {
    private let spinner = NSProgressIndicator()

    init(onBuildBank: @escaping () -> Void) {
        super.init(frame: .zero)
        let s = self.s

        let configured = currentLLM != s.notConfigured
        let dot = SKLiveDot(active: configured)
        let modelName = SKText.label(currentLLM, font: SK.font(13, .medium), color: configured ? SK.ink : SK.secondary)
        let modelCluster = SKBuild.cluster([dot, modelName], spacing: 8)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        constrain(spinner, width: 16, height: 16)

        let buildBtn = SKButton(s.buildAnswerBank, kind: .secondary) { [weak self] in
            self?.spinner.startAnimation(nil)
            onBuildBank()
        }
        let buildCluster = SKBuild.cluster([spinner, buildBtn], spacing: 10)

        let title = SKBuild.pageTitle(s.secAnswer)
        scroll.setRows([
            title,
            SKBuild.divider(),
            SKBuild.controlRow(s.currentLLMLabel, control: modelCluster),
            SKBuild.divider(),
            SKBuild.controlRow(s.buildAnswerBank, control: buildCluster),
            SKBuild.divider(),
        ])
        scroll.gap(18, after: title)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var currentLLM: String {
        if Settings.apiKey("GEMINI_API_KEY") != nil { return "Gemini" }
        if Settings.apiKey("ANTHROPIC_API_KEY") != nil { return "Claude" }
        return s.notConfigured
    }
}

// MARK: - Privacy

final class PrivacySection: SectionScroll {
    private let onDeleteData: () -> Void

    init(onDeleteData: @escaping () -> Void) {
        self.onDeleteData = onDeleteData
        super.init(frame: .zero)
        let s = self.s

        let toggle = SKToggle(isOn: Settings.sendContextToLLM) { Settings.sendContextToLLM = $0 }

        let popup = SKPopup(items: appOptions(), selectedID: Settings.captureTargetBundleID ?? "") { id in
            Settings.captureTargetBundleID = id.isEmpty ? nil : id
        }
        constrain(popup, width: 300, height: 32)

        let title = SKBuild.pageTitle(s.secPrivacy)
        scroll.setRows([
            title,
            SKBuild.divider(),
            SKBuild.textBlock(s.privacyDataFlowTitle, s.privacyDataFlowBody, vPad: 24),
            SKBuild.divider(),
            SKBuild.controlRow(s.sendContextLabel, control: toggle, help: s.sendContextHelp, vPad: 18),
            SKBuild.divider(),
            SKBuild.stackedControl(s.captureTargetLabel, control: popup, help: s.captureTargetHelp),
            SKBuild.divider(),
            deleteBlock(),
        ])
        scroll.gap(18, after: title)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func deleteBlock() -> NSView {
        let s = self.s
        let c = FlippedView()
        let body = SKBuild.help(s.deleteConfirmBody, color: SK.secondary)
        body.translatesAutoresizingMaskIntoConstraints = false
        let btn = SKButton(s.deleteLocalData, kind: .destructive) { [weak self] in self?.confirmDelete() }
        btn.translatesAutoresizingMaskIntoConstraints = false
        c.addSubview(body); c.addSubview(btn)
        NSLayoutConstraint.activate([
            body.topAnchor.constraint(equalTo: c.topAnchor, constant: 22),
            body.leadingAnchor.constraint(equalTo: c.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: c.trailingAnchor),
            btn.topAnchor.constraint(equalTo: body.bottomAnchor, constant: 14),
            btn.trailingAnchor.constraint(equalTo: c.trailingAnchor),
            btn.bottomAnchor.constraint(equalTo: c.bottomAnchor, constant: -22),
        ])
        return c
    }

    private func confirmDelete() {
        let s = self.s
        let alert = NSAlert()
        alert.messageText = s.deleteConfirmTitle
        alert.informativeText = s.deleteConfirmBody
        alert.alertStyle = .critical
        alert.addButton(withTitle: s.deleteButton)
        alert.addButton(withTitle: s.cancel)
        guard let window else { return }
        alert.beginSheetModal(for: window) { [weak self] resp in
            if resp == .alertFirstButtonReturn { self?.onDeleteData() }
        }
    }

    private func appOptions() -> [SKPopup.Item] {
        let s = self.s
        var pairs: [(String, String)] = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil }
            .map { ($0.bundleIdentifier!, $0.localizedName ?? $0.bundleIdentifier!) }
        if let selected = Settings.captureTargetBundleID, !pairs.contains(where: { $0.0 == selected }) {
            pairs.append((selected, selected))
        }
        var seen = Set<String>()
        let apps = pairs
            .filter { seen.insert($0.0).inserted }
            .sorted { $0.1.localizedCaseInsensitiveCompare($1.1) == .orderedAscending }
            .map { SKPopup.Item(id: $0.0, title: $0.1) }
        return [SKPopup.Item(id: "", title: s.captureTargetAuto)] + apps
    }
}

// MARK: - About

final class AboutSection: SectionScroll {
    init(onRerunOnboarding: @escaping () -> Void) {
        super.init(frame: .zero)
        let s = self.s
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"

        let title = SKBuild.pageTitle(s.notchTitle)
        let tagline = SKText.label(s.aboutTagline, font: SK.font(13), color: SK.secondary)
        let versionLabel = SKText.label(version, font: SK.mono(13, .medium), color: SK.ink)
        let rerunBtn = SKButton(s.rerunOnboarding, kind: .secondary, action: onRerunOnboarding)

        scroll.setRows([
            title,
            tagline,
            SKBuild.divider(),
            SKBuild.controlRow(s.aboutVersion, control: versionLabel),
            SKBuild.divider(),
            SKBuild.controlRow(s.rerunOnboarding, control: rerunBtn),
            SKBuild.divider(),
        ])
        scroll.gap(12, after: title)
        scroll.gap(22, after: tagline)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

// MARK: - Live dot

/// A small status dot that breathes when active (a model is configured) — a quiet sign of
/// life, not a blinking LED.
final class SKLiveDot: NSView {
    private let active: Bool
    private var loop: DisplayLoop?
    private var phase: CGFloat = 0

    init(active: Bool) {
        self.active = active
        super.init(frame: .zero)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 8, height: 8) }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard active, window != nil, !SKMotion.reduced else { return }
        if loop == nil {
            loop = DisplayLoop(host: self)
            loop?.onTick = { [weak self] dt in self?.tick(dt) ?? false }
        }
        loop?.start()
    }

    private func tick(_ dt: CGFloat) -> Bool {
        phase += dt
        needsDisplay = true
        return active
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let c = CGPoint(x: bounds.midX, y: bounds.midY)
        let color = active ? SK.accent : SK.tertiary
        if active {
            let glow = 0.5 + 0.5 * sin(phase * 2.2)
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: 3 + 3 * glow, color: SK.accent.withAlphaComponent(0.6 * glow + 0.2).cgColor)
            ctx.setFillColor(color.cgColor)
            ctx.fillEllipse(in: CGRect(x: c.x - 3, y: c.y - 3, width: 6, height: 6))
            ctx.restoreGState()
        } else {
            ctx.setFillColor(color.cgColor)
            ctx.fillEllipse(in: CGRect(x: c.x - 3, y: c.y - 3, width: 6, height: 6))
        }
    }
}

// MARK: - Constraint helper

extension NSView {
    func constrain(_ view: NSView, width: CGFloat, height: CGFloat) {
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalToConstant: width).isActive = true
        view.heightAnchor.constraint(equalToConstant: height).isActive = true
    }
}
