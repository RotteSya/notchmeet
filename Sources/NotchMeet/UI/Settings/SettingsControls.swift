import AppKit

// Hand-drawn controls. Not one is a restyled stock NSControl — each is built in draw(_:) to
// the obsidian + edge-of-light language so there is no cell/layer ordering to fight and they
// read as machined glass. Motion is sprung on the display clock, never a hard snap.

// MARK: - Button

final class SKButton: NSControl {
    enum Kind { case primary, secondary, destructive, plain }

    private let title: String
    private let systemImage: String?
    private let kind: Kind
    private let tintOverride: NSColor?
    private let onTap: () -> Void

    private var hovering = false { didSet { if hovering != oldValue { reflectState() } } }
    private var pressed  = false { didSet { if pressed  != oldValue { reflectState() } } }
    private var enabledFlag = true
    private var tracking: NSTrackingArea?
    private var cachedIntrinsic: NSSize = .zero

    var minWidth: CGFloat = 0 { didSet { invalidateIntrinsicContentSize() } }

    init(_ title: String, systemImage: String? = nil, kind: Kind = .secondary,
         tint: NSColor? = nil, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.kind = kind
        self.tintOverride = tint
        self.onTap = action
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var isEnabledFlag: Bool {
        get { enabledFlag }
        set { enabledFlag = newValue; alphaValue = newValue ? 1 : 0.55; needsDisplay = true }
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var hPad: CGFloat { kind == .plain ? 8 : 15 }
    private var vPad: CGFloat { kind == .plain ? 5 : 8 }
    private var titleFont: NSFont { SK.font(12.5, kind == .primary ? .semibold : .medium) }
    private var iconSize: CGFloat { 11 }
    private var gap: CGFloat { 5 }
    private var corner: CGFloat { kind == .plain ? 6 : 8 }

    override var intrinsicContentSize: NSSize {
        let t = SKText.attributed(title, font: titleFont, color: .white).size()
        var w = ceil(t.width) + hPad * 2
        if systemImage != nil { w += iconSize + gap }
        w = max(w, minWidth)
        let h = ceil(t.height) + vPad * 2
        cachedIntrinsic = NSSize(width: w, height: h)
        return cachedIntrinsic
    }

    private func reflectState() {
        needsDisplay = true
        configureShadow()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t); tracking = t
    }

    override func mouseEntered(with event: NSEvent) { guard enabledFlag else { return }; hovering = true }
    override func mouseExited(with event: NSEvent)  { hovering = false; pressed = false }
    override func mouseDown(with event: NSEvent)    { guard enabledFlag else { return }; pressed = true }
    override func mouseDragged(with event: NSEvent) {
        guard enabledFlag else { return }
        pressed = bounds.contains(convert(event.locationInWindow, from: nil))
    }
    override func mouseUp(with event: NSEvent) {
        guard enabledFlag else { return }
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        pressed = false
        if inside { onTap() }
    }

    private func keyRect() -> CGRect {
        var r = bounds
        if pressed { r = r.insetBy(dx: r.width * 0.012, dy: r.height * 0.03) }
        return r.integralAligned(self)
    }

    private func configureShadow() {
        guard let layer else { return }
        let path = CGPath(roundedRect: keyRect(), cornerWidth: corner, cornerHeight: corner, transform: nil)
        layer.shadowPath = path
        switch kind {
        case .primary:
            layer.shadowColor = SK.accentLo.cgColor
            layer.shadowOpacity = Float(hovering ? 0.55 : 0.42)
            layer.shadowRadius = hovering ? 13 : 10
            layer.shadowOffset = CGSize(width: 0, height: 5)
        case .secondary, .destructive:
            layer.shadowColor = NSColor.black.cgColor
            layer.shadowOpacity = 0.22
            layer.shadowRadius = 3
            layer.shadowOffset = CGSize(width: 0, height: 1)
        case .plain:
            layer.shadowOpacity = 0
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        configureShadow()
        let r = keyRect()
        let path = CGPath(roundedRect: r, cornerWidth: corner, cornerHeight: corner, transform: nil)
        let hair = SK.hairline(self)

        switch kind {
        case .primary:
            ctx.fillLinear(path, r, [(SK.accentHi, 0), (SK.accent, 1)])
            if hovering {
                ctx.fillLinear(path, r, [(SK.ink(0.10), 0), (.clear, 1)], blend: .plusLighter)
            }
            // top-edge specular hairline + grounded lower edge
            strokeEdge(ctx, path, hair, [(SK.ink(0.70), 0), (SK.ink(0.0), 0.5), (SK.accentLo.withAlphaComponent(0.55), 1)])
        case .secondary:
            ctx.addPath(path); ctx.setFillColor(SK.ink(hovering ? 0.095 : 0.052).cgColor); ctx.fillPath()
            SKDither.paint(ctx, in: r, alpha: 0.018)
            strokeEdge(ctx, path, hair, [(SK.ink(hovering ? 0.22 : 0.14), 0), (SK.ink(hovering ? 0.12 : 0.07), 1)])
        case .destructive:
            ctx.addPath(path); ctx.setFillColor(SK.destructive.withAlphaComponent(hovering ? 0.14 : 0.06).cgColor); ctx.fillPath()
            strokeEdge(ctx, path, hair, [(SK.destructive.withAlphaComponent(hovering ? 0.78 : 0.46), 0),
                                         (SK.destructive.withAlphaComponent(hovering ? 0.50 : 0.30), 1)])
        case .plain:
            if hovering {
                ctx.addPath(path); ctx.setFillColor(SK.ink(0.06).cgColor); ctx.fillPath()
            }
        }

        drawContent(ctx, in: r)
    }

    /// Stroke a 1-hairline inset border with a vertical gradient (light from above).
    private func strokeEdge(_ ctx: CGContext, _ path: CGPath, _ width: CGFloat, _ stops: [(NSColor, CGFloat)]) {
        ctx.saveGState()
        ctx.addPath(path); ctx.clip()
        let stroked = path.copy(strokingWithWidth: width * 2, lineCap: .round, lineJoin: .round, miterLimit: 10)
        ctx.addPath(stroked); ctx.clip()
        guard let box = path.boundingBoxOfPath as CGRect? else { ctx.restoreGState(); return }
        ctx.drawLinearGradient(skGradient(stops),
                               start: CGPoint(x: box.midX, y: box.minY),
                               end: CGPoint(x: box.midX, y: box.maxY), options: [])
        ctx.restoreGState()
    }

    private func contentColor() -> NSColor {
        if let tintOverride { return hovering ? tintOverride : tintOverride.withAlphaComponent(0.84) }
        switch kind {
        case .primary:     return NSColor(srgbRed: 0.043, green: 0.055, blue: 0.094, alpha: 1) // ink on accent
        case .secondary:   return hovering ? SK.ink : SK.ink.withAlphaComponent(0.88)
        case .destructive: return SK.destructive.withAlphaComponent(hovering ? 1 : 0.90)
        case .plain:       return hovering ? SK.ink : SK.secondary
        }
    }

    private func drawContent(_ ctx: CGContext, in r: CGRect) {
        let color = contentColor()
        let attr = SKText.attributed(title, font: titleFont, color: color)
        let tSize = attr.size()
        var contentW = tSize.width
        var img: NSImage?
        if let systemImage {
            img = skSymbol(systemImage, size: iconSize, weight: .semibold, color: color)
            contentW += (img?.size.width ?? iconSize) + gap
        }
        var x = r.midX - contentW / 2
        let cy = r.midY
        if let img {
            let isz = img.size
            img.draw(in: CGRect(x: x, y: cy - isz.height / 2, width: isz.width, height: isz.height),
                     from: .zero, operation: .sourceOver, fraction: 1)
            x += isz.width + gap
        }
        attr.draw(at: CGPoint(x: x, y: cy - tSize.height / 2))
    }
}

// MARK: - Segmented (sliding thumb)

final class SKSegmented: NSControl {
    private let titles: [String]
    private let onChange: (Int) -> Void
    private(set) var selected: Int

    private var thumb: Spring
    private var tracking: NSTrackingArea?
    private var hoverIndex: Int = -1

    init(titles: [String], selected: Int, action: @escaping (Int) -> Void) {
        self.titles = titles
        self.selected = selected
        self.onChange = action
        self.thumb = Spring(CGFloat(selected), stiffness: 360, damping: 30)
        super.init(frame: .zero)
        wantsLayer = true
        setAccessibilityRole(.radioGroup)
        loopHost = DisplayLoop(host: self)
        loopHost?.onTick = { [weak self] dt in self?.tick(dt) ?? false }
    }
    private var loopHost: DisplayLoop?

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: max(180, CGFloat(titles.count) * 90), height: 30) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func setSelected(_ i: Int, animated: Bool = true) {
        guard i != selected, titles.indices.contains(i) else { return }
        selected = i
        if animated && !SKMotion.reduced { thumb.target = CGFloat(i); loopHost?.start() }
        else { thumb.snap(CGFloat(i)); needsDisplay = true }
    }

    private func tick(_ dt: CGFloat) -> Bool {
        let moving = thumb.step(dt)
        needsDisplay = true
        return moving
    }

    private func segWidth() -> CGFloat { (bounds.width - 4) / CGFloat(titles.count) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeInActiveApp, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t); tracking = t
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let idx = Int((p.x - 2) / max(1, segWidth()))
        let clamped = min(max(idx, 0), titles.count - 1)
        if clamped != hoverIndex { hoverIndex = clamped; needsDisplay = true }
    }
    override func mouseExited(with event: NSEvent) { hoverIndex = -1; needsDisplay = true }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let idx = Int((p.x - 2) / max(1, segWidth()))
        let clamped = min(max(idx, 0), titles.count - 1)
        if clamped != selected { setSelected(clamped); onChange(clamped) }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let b = bounds
        let hair = SK.hairline(self)

        // Trough — an inset obsidian well.
        let trough = CGPath(roundedRect: b, cornerWidth: 9, cornerHeight: 9, transform: nil)
        ctx.addPath(trough); ctx.setFillColor(SK.ink(0.05).cgColor); ctx.fillPath()
        ctx.saveGState(); ctx.addPath(trough); ctx.clip()
        ctx.drawLinearGradient(skGradient([(NSColor.black.withAlphaComponent(0.28), 0), (.clear, 0.5)]),
                               start: CGPoint(x: b.midX, y: b.minY), end: CGPoint(x: b.midX, y: b.maxY), options: [])
        ctx.restoreGState()
        strokeInset(ctx, trough, hair, SK.ink(0.10))

        // Thumb — a convex glass chip that springs between segments.
        let sw = segWidth()
        let tx = 2 + thumb.value * sw
        let thumbRect = CGRect(x: tx + 1.5, y: 3, width: sw - 3, height: b.height - 6)
        let thumbPath = CGPath(roundedRect: thumbRect, cornerWidth: 7, cornerHeight: 7, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 1.5), blur: 5, color: NSColor.black.withAlphaComponent(0.45).cgColor)
        ctx.addPath(thumbPath); ctx.setFillColor(NSColor(white: 0.18, alpha: 1).cgColor); ctx.fillPath()
        ctx.restoreGState()
        ctx.fillLinear(thumbPath, thumbRect, [(SK.ink(0.16), 0), (SK.ink(0.05), 0.5), (SK.ink(0.02), 1)])
        // a periwinkle breath along the thumb's lit top edge
        ctx.fillLinear(thumbPath, thumbRect, [(SK.accentHi.withAlphaComponent(0.10), 0), (.clear, 0.55)], blend: .plusLighter)
        SKDither.paint(ctx, in: thumbRect, alpha: 0.02)
        strokeInset(ctx, thumbPath, hair, SK.ink(0.20))

        // Labels.
        for (i, title) in titles.enumerated() {
            let dist = abs(CGFloat(i) - thumb.value)
            let onThumb = 1 - min(dist, 1)
            let base = SK.ink(0.55)
            let lit = SK.ink
            let color = base.blended(withFraction: onThumb, of: lit) ?? lit
            let weight: NSFont.Weight = onThumb > 0.5 ? .semibold : .medium
            let attr = SKText.attributed(title, font: SK.font(12.5, weight), color: color)
            let s = attr.size()
            let segX = 2 + CGFloat(i) * sw
            attr.draw(at: CGPoint(x: segX + (sw - s.width) / 2, y: b.midY - s.height / 2))
        }
    }

    private func strokeInset(_ ctx: CGContext, _ path: CGPath, _ width: CGFloat, _ color: NSColor) {
        ctx.saveGState(); ctx.addPath(path); ctx.clip()
        let stroked = path.copy(strokingWithWidth: width * 2, lineCap: .round, lineJoin: .round, miterLimit: 10)
        ctx.addPath(stroked); ctx.setFillColor(color.cgColor); ctx.fillPath()
        ctx.restoreGState()
    }
}

// MARK: - Toggle (custom switch)

final class SKToggle: NSControl {
    private let onChange: (Bool) -> Void
    private(set) var isOn: Bool
    private var knob: Spring
    private var loopHost: DisplayLoop?
    private var hovering = false { didSet { needsDisplay = true } }
    private var tracking: NSTrackingArea?

    init(isOn: Bool, action: @escaping (Bool) -> Void) {
        self.isOn = isOn
        self.onChange = action
        self.knob = Spring(isOn ? 1 : 0, stiffness: 420, damping: 28)
        super.init(frame: .zero)
        wantsLayer = true
        setAccessibilityRole(.checkBox)
        loopHost = DisplayLoop(host: self)
        loopHost?.onTick = { [weak self] dt in self?.tick(dt) ?? false }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 40, height: 24) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func setOn(_ on: Bool, animated: Bool = true) {
        guard on != isOn else { return }
        isOn = on
        if animated && !SKMotion.reduced { knob.target = on ? 1 : 0; loopHost?.start() }
        else { knob.snap(on ? 1 : 0); needsDisplay = true }
    }

    private func tick(_ dt: CGFloat) -> Bool {
        let moving = knob.step(dt)
        needsDisplay = true
        return moving
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t); tracking = t
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) {
        setOn(!isOn); onChange(isOn)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let t = knob.value
        let trackRect = CGRect(x: 0, y: (bounds.height - 22) / 2, width: 38, height: 22)
        let track = CGPath(roundedRect: trackRect, cornerWidth: 11, cornerHeight: 11, transform: nil)
        let hair = SK.hairline(self)

        // Off trough → on accent fill, cross-faded by the spring.
        ctx.addPath(track); ctx.setFillColor(SK.ink(0.08).cgColor); ctx.fillPath()
        if t > 0.001 {
            ctx.saveGState(); ctx.addPath(track); ctx.clip()
            ctx.setAlpha(t)
            ctx.drawLinearGradient(skGradient([(SK.accentHi, 0), (SK.accent, 1)]),
                                   start: CGPoint(x: trackRect.midX, y: trackRect.minY),
                                   end: CGPoint(x: trackRect.midX, y: trackRect.maxY), options: [])
            // inner top sheen
            ctx.setBlendMode(.plusLighter)
            ctx.drawLinearGradient(skGradient([(SK.ink(0.22), 0), (.clear, 0.6)]),
                                   start: CGPoint(x: trackRect.midX, y: trackRect.minY),
                                   end: CGPoint(x: trackRect.midX, y: trackRect.maxY), options: [])
            ctx.restoreGState()
        }
        // border
        ctx.saveGState(); ctx.addPath(track); ctx.clip()
        let strokeColor = SK.ink(0.12).blended(withFraction: t, of: SK.accentLo.withAlphaComponent(0.7)) ?? SK.ink(0.12)
        let stroked = track.copy(strokingWithWidth: hair * 2, lineCap: .round, lineJoin: .round, miterLimit: 10)
        ctx.addPath(stroked); ctx.setFillColor(strokeColor.cgColor); ctx.fillPath()
        ctx.restoreGState()

        // Knob — convex, springs across; brightens a touch on hover.
        let d: CGFloat = 18
        let travel = trackRect.width - d - 4
        let kx = trackRect.minX + 2 + travel * t
        let knobRect = CGRect(x: kx, y: trackRect.midY - d / 2, width: d, height: d)
        let knobPath = CGPath(ellipseIn: knobRect, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 1), blur: 3, color: NSColor.black.withAlphaComponent(0.5).cgColor)
        ctx.addPath(knobPath); ctx.setFillColor(NSColor(white: hovering ? 1.0 : 0.97, alpha: 1).cgColor); ctx.fillPath()
        ctx.restoreGState()
        ctx.fillLinear(knobPath, knobRect, [(SK.ink(0.20), 0), (.clear, 0.5)], blend: .plusLighter)
    }
}

// MARK: - Popup (glass field opening a real NSMenu)

final class SKPopup: NSControl {
    struct Item { let id: String; let title: String }
    private var items: [Item]
    private var selectedID: String
    private let onSelect: (String) -> Void
    private var hovering = false { didSet { needsDisplay = true } }
    private var tracking: NSTrackingArea?

    init(items: [Item], selectedID: String, action: @escaping (String) -> Void) {
        self.items = items
        self.selectedID = selectedID
        self.onSelect = action
        super.init(frame: .zero)
        wantsLayer = true
        setAccessibilityRole(.popUpButton)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 240, height: 32) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func update(items: [Item], selectedID: String) {
        self.items = items; self.selectedID = selectedID; needsDisplay = true
    }

    private var currentTitle: String { items.first { $0.id == selectedID }?.title ?? "" }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t); tracking = t
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func mouseDown(with event: NSEvent) {
        let menu = NSMenu()
        menu.appearance = NSAppearance(named: .darkAqua)
        menu.font = SK.font(13)
        for item in items {
            let mi = NSMenuItem(title: item.title, action: #selector(pick(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = item.id
            mi.state = item.id == selectedID ? .on : .off
            menu.addItem(mi)
        }
        menu.popUp(positioning: menu.item(withTitle: currentTitle),
                   at: NSPoint(x: 0, y: bounds.height + 4), in: self)
    }

    @objc private func pick(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, id != selectedID else { return }
        selectedID = id; needsDisplay = true; onSelect(id)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let b = bounds
        let hair = SK.hairline(self)
        let path = CGPath(roundedRect: b, cornerWidth: 8, cornerHeight: 8, transform: nil)

        ctx.addPath(path); ctx.setFillColor(SK.ink(hovering ? 0.075 : 0.05).cgColor); ctx.fillPath()
        ctx.fillLinear(path, b, [(SK.ink(0.05), 0), (.clear, 0.5)], blend: .plusLighter)
        SKDither.paint(ctx, in: b, alpha: 0.016)
        ctx.saveGState(); ctx.addPath(path); ctx.clip()
        let stroked = path.copy(strokingWithWidth: hair * 2, lineCap: .round, lineJoin: .round, miterLimit: 10)
        ctx.addPath(stroked); ctx.setFillColor(SK.ink(hovering ? 0.18 : 0.12).cgColor); ctx.fillPath()
        ctx.restoreGState()

        let attr = SKText.attributed(currentTitle, font: SK.font(13), color: hovering ? SK.ink : SK.ink.withAlphaComponent(0.9))
        let s = attr.size()
        let maxTextW = b.width - 38
        attr.draw(in: CGRect(x: 12, y: b.midY - s.height / 2, width: min(s.width, maxTextW), height: s.height))

        if let chev = skSymbol("chevron.up.chevron.down", size: 10, weight: .semibold, color: SK.secondary) {
            chev.draw(in: CGRect(x: b.maxX - 22, y: b.midY - chev.size.height / 2,
                                 width: chev.size.width, height: chev.size.height),
                      from: .zero, operation: .sourceOver, fraction: 1)
        }
    }
}

// MARK: - Text field (obsidian well + accent focus bloom)

final class SKField: NSView, NSTextFieldDelegate {
    let field: NSTextField
    private let secure: Bool
    var onChange: ((String) -> Void)?
    var onSubmit: (() -> Void)?
    private var focused = false { didSet { needsDisplay = true } }

    init(placeholder: String, secure: Bool = false, monospaced: Bool = false) {
        self.secure = secure
        self.field = secure ? NSSecureTextField() : NSTextField()
        super.init(frame: .zero)
        wantsLayer = true

        field.placeholderAttributedString = SKText.attributed(
            placeholder, font: monospaced ? SK.mono(12) : SK.font(13), color: SK.ink(0.30))
        field.font = monospaced ? SK.mono(12) : SK.font(13)
        field.textColor = SK.ink
        field.drawsBackground = false
        field.isBordered = false
        field.isBezeled = false
        field.focusRingType = .none
        field.delegate = self
        field.target = self
        field.action = #selector(submit)
        field.lineBreakMode = .byClipping
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 11),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -11),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 34) }

    var stringValue: String {
        get { field.stringValue }
        set { field.stringValue = newValue }
    }

    func focus() { window?.makeFirstResponder(field) }

    func controlTextDidBeginEditing(_ obj: Notification) { focused = true }
    func controlTextDidEndEditing(_ obj: Notification) { focused = false }
    func controlTextDidChange(_ obj: Notification) { onChange?(field.stringValue) }

    @objc private func submit() { onSubmit?() }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let b = bounds
        let hair = SK.hairline(self)
        let path = CGPath(roundedRect: b, cornerWidth: 8, cornerHeight: 8, transform: nil)

        ctx.addPath(path); ctx.setFillColor(SK.ink(0.045).cgColor); ctx.fillPath()
        // inset top shadow so the well reads as recessed
        ctx.fillLinear(path, b, [(NSColor.black.withAlphaComponent(0.22), 0), (.clear, 0.4)])

        ctx.saveGState(); ctx.addPath(path); ctx.clip()
        let borderColor = focused ? SK.accent.withAlphaComponent(0.85) : SK.ink(0.13)
        let w = focused ? hair * 4 : hair * 2
        let stroked = path.copy(strokingWithWidth: w, lineCap: .round, lineJoin: .round, miterLimit: 10)
        ctx.addPath(stroked); ctx.setFillColor(borderColor.cgColor); ctx.fillPath()
        ctx.restoreGState()

        if focused {
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: 7, color: SK.accent.withAlphaComponent(0.45).cgColor)
            ctx.addPath(path); ctx.setStrokeColor(SK.accent.withAlphaComponent(0.001).cgColor)
            ctx.setLineWidth(1); ctx.strokePath()
            ctx.restoreGState()
        }
    }
}

// MARK: - Text well (themed NSTextView for the script editor)

final class SKTextWell: NSView {
    private let scroll = NSScrollView()
    let textView = NSTextView()
    var onChange: ((String) -> Void)?

    init(monospaced: Bool = true) {
        super.init(frame: .zero)
        wantsLayer = true

        textView.isRichText = false
        textView.font = monospaced ? SK.mono(12.5) : SK.font(13)
        textView.textColor = SK.ink
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.insertionPointColor = SK.accent
        textView.selectedTextAttributes = [.backgroundColor: SK.accent.withAlphaComponent(0.28)]
        textView.textContainerInset = NSSize(width: 8, height: 9)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.allowsUndo = true
        textView.delegate = self
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true

        scroll.documentView = textView
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.contentInsets = NSEdgeInsets(top: 2, left: 2, bottom: 2, right: 2)
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            scroll.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    var string: String {
        get { textView.string }
        set { textView.string = newValue }
    }

    func focus() { window?.makeFirstResponder(textView) }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let b = bounds
        let hair = SK.hairline(self)
        let path = CGPath(roundedRect: b, cornerWidth: 9, cornerHeight: 9, transform: nil)
        ctx.addPath(path); ctx.setFillColor(SK.ink(0.04).cgColor); ctx.fillPath()
        ctx.fillLinear(path, b, [(NSColor.black.withAlphaComponent(0.20), 0), (.clear, 0.22)])
        ctx.saveGState(); ctx.addPath(path); ctx.clip()
        let stroked = path.copy(strokingWithWidth: hair * 2, lineCap: .round, lineJoin: .round, miterLimit: 10)
        ctx.addPath(stroked); ctx.setFillColor(SK.ink(0.12).cgColor); ctx.fillPath()
        ctx.restoreGState()
    }
}

extension SKTextWell: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) { onChange?(textView.string) }
}
