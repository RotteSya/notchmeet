import AppKit
import Combine

// The window chrome: a full-height obsidian sidebar (traffic lights float over its top, the
// modern macOS look), a liquid selection pill that springs between items on the display
// clock, and a detail stage that crossfades sections as one body instead of snapping. The
// living aurora sits behind it all and pools light under the rail.

// MARK: - Sections

enum SettingsSection: String, CaseIterable, Identifiable {
    case general, scripts, keys, answer, privacy, about
    var id: String { rawValue }

    var icon: String {
        switch self {
        case .general: "slider.horizontal.3"
        case .scripts: "doc.text"
        case .keys:    "key.fill"
        case .answer:  "sparkles"
        case .privacy: "lock.shield"
        case .about:   "info.circle"
        }
    }

    func title(_ s: AppStrings) -> String {
        switch self {
        case .general: s.secGeneral
        case .scripts: s.secScripts
        case .keys:    s.secKeys
        case .answer:  s.secAnswer
        case .privacy: s.secPrivacy
        case .about:   s.secAbout
        }
    }
}

// MARK: - Root

final class SettingsRoot: NSView {
    private let store: ScriptStore
    private let onKeysChanged: () -> Void
    private let onBuildBank: () -> Void
    private let onDeleteData: () -> Void
    private let onRerunOnboarding: () -> Void

    private let backdrop = SettingsBackdrop()
    private let sidebar: SKSidebar
    private let glass = SidebarGlass()
    private let detailContainer = ContentPlaneView()

    private var current: SettingsSection
    private var currentView: NSView?
    private var incoming: NSView?
    private var outgoing: NSView?
    private lazy var tween: DisplayTween = {
        let t = DisplayTween(host: self)
        t.ease = { x in 1 - pow(1 - x, 3) }
        t.onChange = { [weak self] v in self?.applyTransition(v) }
        return t
    }()

    private var languageCancellable: AnyCancellable?
    // A clean edge-to-edge split (like System Settings): one continuous glass sidebar with the
    // traffic lights on it, and a flush content pane, divided by a single hairline. No floating
    // card — the two halves share one coherent grid.
    private let sidebarWidth: CGFloat = 220

    private var strings: AppStrings { AppStrings(language: AppLanguageStore.shared.language) }

    init(store: ScriptStore, initial: SettingsSection,
         onKeysChanged: @escaping () -> Void,
         onBuildBank: @escaping () -> Void,
         onDeleteData: @escaping () -> Void,
         onRerunOnboarding: @escaping () -> Void) {
        self.store = store
        self.current = initial
        self.onKeysChanged = onKeysChanged
        self.onBuildBank = onBuildBank
        self.onDeleteData = onDeleteData
        self.onRerunOnboarding = onRerunOnboarding
        self.sidebar = SKSidebar()
        super.init(frame: NSRect(x: 0, y: 0, width: 820, height: 580))
        wantsLayer = true

        glass.embed(sidebar, cornerRadius: 0)
        addSubview(backdrop)
        addSubview(glass)
        addSubview(detailContainer)

        sidebar.configure(sections: SettingsSection.allCases, strings: strings, selected: current)
        sidebar.onSelect = { [weak self] section in self?.show(section, animated: true) }

        let first = makeSection(current)
        mount(first)
        currentView = first

        languageCancellable = AppLanguageStore.shared.$language
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.applyLanguage() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let b = bounds
        backdrop.frame = b
        // Edge-to-edge split: glass sidebar flush on the left (lights on its glass), content
        // pane flush on the right. The window's corner radius rounds the four outer corners.
        glass.frame = NSRect(x: 0, y: 0, width: sidebarWidth, height: b.height)
        detailContainer.frame = NSRect(x: sidebarWidth, y: 0,
                                       width: max(0, b.width - sidebarWidth), height: b.height)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        backdrop.setRunning(window != nil)
        sidebar.placePillImmediately(for: current)
    }

    /// Pause/resume the Metal backdrop with window visibility.
    func setRunning(_ running: Bool) { backdrop.setRunning(running) }

    // MARK: Navigation

    func show(_ section: SettingsSection, animated: Bool) {
        guard section != current || currentView == nil else { return }
        current = section
        sidebar.select(section, animated: animated)

        let newView = makeSection(section)
        mount(newView)

        // Finalize any in-flight transition before starting a new one.
        if let inc = incoming { inc.layer?.opacity = 1; inc.layer?.transform = CATransform3DIdentity }
        outgoing?.removeFromSuperview()

        if !animated || SKMotion.reduced {
            currentView?.removeFromSuperview()
            currentView = newView
            incoming = nil; outgoing = nil
            return
        }

        outgoing = currentView
        incoming = newView
        currentView = newView
        newView.wantsLayer = true
        newView.layer?.opacity = 0
        tween.set(0)
        tween.animate(to: 1, duration: 0.34)
    }

    private func applyTransition(_ t: CGFloat) {
        if let inc = incoming?.layer {
            inc.opacity = Float(t)
            inc.transform = CATransform3DMakeTranslation((1 - t) * 14, 0, 0)
        }
        if let out = outgoing?.layer {
            out.opacity = Float(1 - t)
            out.transform = CATransform3DMakeTranslation(-10 * t, 0, 0)
        }
        if t >= 1 {
            outgoing?.removeFromSuperview()
            outgoing = nil
            incoming?.layer?.transform = CATransform3DIdentity
            incoming = nil
        }
    }

    private func mount(_ view: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        detailContainer.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: detailContainer.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: detailContainer.trailingAnchor),
            view.topAnchor.constraint(equalTo: detailContainer.topAnchor, constant: 6),
            view.bottomAnchor.constraint(equalTo: detailContainer.bottomAnchor),
        ])
    }

    private func makeSection(_ section: SettingsSection) -> NSView {
        switch section {
        case .general: return GeneralSection()
        case .scripts: return ScriptsSection(store: store)
        case .keys:    return KeysSection(onKeysChanged: onKeysChanged)
        case .answer:  return AnswerSection(onBuildBank: onBuildBank)
        case .privacy: return PrivacySection(onDeleteData: onDeleteData)
        case .about:   return AboutSection(onRerunOnboarding: onRerunOnboarding)
        }
    }

    private func applyLanguage() {
        sidebar.configure(sections: SettingsSection.allCases, strings: strings, selected: current)
        sidebar.placePillImmediately(for: current)
        // Rebuild the visible section with fresh copy (no animation — it's the same page).
        let rebuilt = makeSection(current)
        mount(rebuilt)
        currentView?.removeFromSuperview()
        outgoing?.removeFromSuperview(); incoming = nil; outgoing = nil
        currentView = rebuilt
    }
}

// MARK: - Content plane

/// The reading pane: a calm, near-opaque obsidian surface (the living aurora is kept to the
/// glass rail so type stays crisp here), with a whisper of top-light and a single hairline
/// seam on its left edge dividing it from the sidebar.
final class ContentPlaneView: FlippedView {
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let b = bounds
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.62).cgColor)
        ctx.fill(b)
        // top sheen — light falling from above
        ctx.saveGState()
        ctx.setBlendMode(.plusLighter)
        ctx.drawLinearGradient(skGradient([(SK.ink(0.04), 0), (.clear, 0.12)]),
                               start: CGPoint(x: b.midX, y: 0), end: CGPoint(x: b.midX, y: b.height), options: [])
        ctx.restoreGState()
        // seam hairline at the sidebar boundary
        let hair = SK.hairline(self)
        ctx.setFillColor(SK.ink(0.085).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: hair, height: b.height))
    }
}

// MARK: - Sidebar glass (Liquid Glass)

/// Backs the sidebar with Apple's Liquid Glass material (`NSGlassEffectView`, macOS 26+),
/// refracting the living aurora behind it. A smoked-obsidian tint keeps it on-brand and white
/// text legible. Falls back to the classic vibrancy sidebar on older macOS.
final class SidebarGlass: NSView {
    override var isFlipped: Bool { true }

    func embed(_ content: NSView, cornerRadius: CGFloat) {
        content.translatesAutoresizingMaskIntoConstraints = false
        if #available(macOS 26.0, *) {
            let g = NSGlassEffectView()
            g.style = .regular
            g.cornerRadius = cornerRadius
            g.tintColor = NSColor(srgbRed: 0.050, green: 0.060, blue: 0.098, alpha: 0.62)
            g.contentView = content
            host(g)
        } else {
            let v = NSVisualEffectView()
            v.material = .sidebar
            v.blendingMode = .behindWindow
            v.state = .active
            if cornerRadius > 0 {
                v.wantsLayer = true
                v.layer?.cornerRadius = cornerRadius
                v.layer?.masksToBounds = true
            }
            host(v)
            v.addSubview(content)
            pin(content, to: v)
        }
    }

    private func host(_ v: NSView) {
        v.translatesAutoresizingMaskIntoConstraints = false
        addSubview(v)
        pin(v, to: self)
    }

    private func pin(_ v: NSView, to other: NSView) {
        NSLayoutConstraint.activate([
            v.leadingAnchor.constraint(equalTo: other.leadingAnchor),
            v.trailingAnchor.constraint(equalTo: other.trailingAnchor),
            v.topAnchor.constraint(equalTo: other.topAnchor),
            v.bottomAnchor.constraint(equalTo: other.bottomAnchor),
        ])
    }
}

// MARK: - Sidebar

final class SKSidebar: FlippedView {
    var onSelect: ((SettingsSection) -> Void)?

    private var sections: [SettingsSection] = []
    private var rows: [SKSidebarRow] = []
    private let pill = PillView()
    private var selected: SettingsSection = .general
    private var strings = AppStrings(language: .zh)

    private var pillSpring = Spring(0, stiffness: 360, damping: 30)
    private var loop: DisplayLoop?

    private let trafficClearance: CGFloat = 34   // the traffic lights sit on the sidebar glass; clear them
    private let identityHeight: CGFloat = 50
    private let navTopGap: CGFloat = 14
    private let rowH: CGFloat = 38
    private let sideInset: CGFloat = 12

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(pill)
        loop = DisplayLoop(host: self)
        loop?.onTick = { [weak self] dt in self?.tick(dt) ?? false }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(sections: [SettingsSection], strings: AppStrings, selected: SettingsSection) {
        self.sections = sections
        self.strings = strings
        self.selected = selected
        rows.forEach { $0.removeFromSuperview() }
        rows = sections.map { section in
            let row = SKSidebarRow(section: section, title: section.title(strings), icon: section.icon)
            row.onTap = { [weak self] in self?.onSelect?(section) }
            row.isSelectedRow = (section == selected)
            addSubview(row)
            return row
        }
        needsLayout = true
        needsDisplay = true
    }

    private var navTop: CGFloat { trafficClearance + identityHeight + navTopGap }

    override func layout() {
        super.layout()
        let w = bounds.width
        for (i, row) in rows.enumerated() {
            row.frame = NSRect(x: sideInset, y: navTop + CGFloat(i) * rowH, width: w - sideInset * 2, height: rowH)
        }
        positionPill(at: pillSpring.value)
    }

    private func index(of section: SettingsSection) -> Int { sections.firstIndex(of: section) ?? 0 }

    private func positionPill(at value: CGFloat) {
        let w = bounds.width
        pill.frame = NSRect(x: sideInset, y: navTop + value * rowH + 2, width: w - sideInset * 2, height: rowH - 4)
    }

    func placePillImmediately(for section: SettingsSection) {
        pillSpring.snap(CGFloat(index(of: section)))
        positionPill(at: pillSpring.value)
    }

    func select(_ section: SettingsSection, animated: Bool) {
        selected = section
        rows.forEach { $0.isSelectedRow = ($0.section == section) }
        let target = CGFloat(index(of: section))
        if animated && !SKMotion.reduced {
            pillSpring.target = target
            loop?.start()
        } else {
            pillSpring.snap(target)
            positionPill(at: pillSpring.value)
        }
    }

    private func tick(_ dt: CGFloat) -> Bool {
        let moving = pillSpring.step(dt)
        positionPill(at: pillSpring.value)
        return moving
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        // The Liquid Glass material is the background now (see `SidebarGlass`); the sidebar view
        // itself stays transparent and only draws the identity mark + footer over the glass.

        // Identity — app mark + wordmark.
        let iconSize: CGFloat = 26
        let iconRect = CGRect(x: 22, y: trafficClearance + (identityHeight - iconSize) / 2 - 4, width: iconSize, height: iconSize)
        if let icon = OB.icon() {
            ctx.saveGState()
            let clip = CGPath(roundedRect: iconRect, cornerWidth: iconSize * 0.23, cornerHeight: iconSize * 0.23, transform: nil)
            ctx.addPath(clip); ctx.clip()
            icon.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1)
            ctx.restoreGState()
            ctx.addPath(clip)
            ctx.setStrokeColor(SK.ink(0.18).cgColor); ctx.setLineWidth(SK.hairline(self)); ctx.strokePath()
        }
        let name = SKText.attributed("NotchMeet", font: SK.font(15, .semibold), color: SK.ink, tracking: -0.2)
        name.draw(at: CGPoint(x: iconRect.maxX + 11, y: iconRect.minY - 1))
        let sub = SKText.attributed(strings.settings, font: SK.font(11.5), color: SK.secondary)
        sub.draw(at: CGPoint(x: iconRect.maxX + 11, y: iconRect.minY + 14))
    }
}

/// The sprung selection chip — a glass pill with a leading periwinkle tick of light and a
/// faint inner glow. Drawn behind the rows so their content sits over it.
final class PillView: FlippedView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let b = bounds
        let path = CGPath(roundedRect: b, cornerWidth: 9, cornerHeight: 9, transform: nil)
        // A brighter glass highlight that reads clearly as the selection on the Liquid Glass rail.
        ctx.addPath(path); ctx.setFillColor(SK.ink(0.14).cgColor); ctx.fillPath()
        ctx.fillLinear(path, b, [(SK.ink(0.10), 0), (.clear, 0.6)], blend: .plusLighter)
        // periwinkle breath
        ctx.fillLinear(path, b, [(SK.accent.withAlphaComponent(0.16), 0), (SK.accent.withAlphaComponent(0.05), 1)], blend: .plusLighter)
        let hair = SK.hairline(self)
        ctx.saveGState(); ctx.addPath(path); ctx.clip()
        let stroked = path.copy(strokingWithWidth: hair * 2, lineCap: .round, lineJoin: .round, miterLimit: 10)
        ctx.addPath(stroked); ctx.setFillColor(SK.ink(0.20).cgColor); ctx.fillPath()
        ctx.restoreGState()
        // leading accent tick
        let tick = CGPath(roundedRect: CGRect(x: 4, y: b.midY - 7, width: 3, height: 14), cornerWidth: 1.5, cornerHeight: 1.5, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 5, color: SK.accent.withAlphaComponent(0.7).cgColor)
        ctx.addPath(tick); ctx.setFillColor(SK.accent.cgColor); ctx.fillPath()
        ctx.restoreGState()
    }
}

final class SKSidebarRow: NSView {
    let section: SettingsSection
    private let title: String
    private let iconName: String
    var onTap: (() -> Void)?

    var isSelectedRow = false { didSet { if isSelectedRow != oldValue { needsDisplay = true } } }
    private var hovering = false { didSet { if hovering != oldValue { needsDisplay = true } } }
    private var tracking: NSTrackingArea?

    init(section: SettingsSection, title: String, icon: String) {
        self.section = section
        self.title = title
        self.iconName = icon
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
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t); tracking = t
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) { onTap?() }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let b = bounds
        // Hover wash (only when not the selected row — the pill owns that background).
        if hovering && !isSelectedRow {
            let path = CGPath(roundedRect: b.insetBy(dx: 0, dy: 2), cornerWidth: 8, cornerHeight: 8, transform: nil)
            ctx.addPath(path); ctx.setFillColor(SK.ink(0.05).cgColor); ctx.fillPath()
        }
        let fg: NSColor = isSelectedRow ? SK.ink : (hovering ? SK.ink.withAlphaComponent(0.92) : SK.secondary)
        let weight: NSFont.Weight = isSelectedRow ? .medium : .regular
        if let img = skSymbol(iconName, size: 13, weight: isSelectedRow ? .semibold : .regular,
                              color: isSelectedRow ? SK.accentHi : fg) {
            img.draw(in: CGRect(x: 14, y: b.midY - img.size.height / 2, width: img.size.width, height: img.size.height),
                     from: .zero, operation: .sourceOver, fraction: 1)
        }
        let attr = SKText.attributed(title, font: SK.font(13, weight), color: fg)
        let s = attr.size()
        attr.draw(at: CGPoint(x: 40, y: b.midY - s.height / 2))
    }
}
