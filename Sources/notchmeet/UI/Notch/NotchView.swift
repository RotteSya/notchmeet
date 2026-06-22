import AppKit
import Combine

/// The notch's content, in pure AppKit. A flipped `NSView` that hosts the obsidian surface, a
/// collapsed menu-bar bar, and an expanded card, crossfading between the two as the controller
/// drives `model.expanded`. The slab radii + content opacity tween on a display clock matched
/// to the controller's panel-frame animation, so frame and contents arrive as one body.
final class NotchView: NSView {
    private let model: AnswerModel
    private let onHover: (Bool) -> Void
    private let onSettings: () -> Void
    private let onToggleRecording: () -> Void

    // Surface (fills the whole panel incl. the transparent shadow margin).
    private let surface = NotchSurfaceView()

    // Collapsed bar.
    private let collapsedBar = FlippedContainer()
    private let recordHit = RecordHitView()
    private let collapsedStatus = NotchStatusMark()
    private let collapsedREC = NotchView.makeRECLabel()
    private lazy var collapsedSettings = NotchControlButton(
        systemName: "gearshape", tint: NotchPalette.secondary, label: AppStrings.current.settings,
        action: { [weak self] in self?.onSettings() })

    // Expanded card.
    private let expandedContent = FlippedContainer()
    private let headerStatus = NotchStatusMark()
    private let headerREC = NotchView.makeRECLabel()
    private let statusText = NotchView.makeLabel(size: 11.5, weight: .semibold, color: NotchPalette.primary)
    private lazy var recordButton = NotchControlButton(
        systemName: "record.circle", tint: NotchPalette.secondary, label: AppStrings.current.startRecording,
        action: { [weak self] in self?.onToggleRecording() })
    private lazy var settingsButton = NotchControlButton(
        systemName: "gearshape", tint: NotchPalette.secondary, label: AppStrings.current.settings,
        action: { [weak self] in self?.onSettings() })
    private let heardLabel = NotchView.makeLabel(size: 10, weight: .semibold, color: NotchPalette.tertiary)
    private let heardValue: NSTextField = {
        let f = NotchView.makeLabel(size: 12, weight: .regular, color: NotchPalette.secondary)
        f.isSelectable = true
        f.maximumNumberOfLines = 2
        f.lineBreakMode = .byTruncatingTail
        f.cell?.wraps = true
        return f
    }()
    private let intentChip = IntentChipView()
    private let answerLabel: NSTextField = {
        let f = NotchView.makeLabel(size: 15, weight: .regular, color: NotchPalette.primary)
        f.isSelectable = true
        f.maximumNumberOfLines = 0
        f.lineBreakMode = .byWordWrapping
        f.cell?.wraps = true
        return f
    }()

    private lazy var morph = DisplayTween(host: self, value: 0)
    private var wasExpanded = false
    private var hovering = false
    private var trackingAreaRef: NSTrackingArea?
    private var cancellables = Set<AnyCancellable>()

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    init(model: AnswerModel,
         onHover: @escaping (Bool) -> Void,
         onSettings: @escaping () -> Void,
         onToggleRecording: @escaping () -> Void) {
        self.model = model
        self.onHover = onHover
        self.onSettings = onSettings
        self.onToggleRecording = onToggleRecording
        super.init(frame: .zero)
        build()
        observe()
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    // MARK: Build

    private func build() {
        addSubview(surface)

        recordHit.onClick = { [weak self] in self?.onToggleRecording() }
        recordHit.addSubview(collapsedStatus)
        recordHit.addSubview(collapsedREC)
        collapsedBar.addSubview(recordHit)
        collapsedBar.addSubview(collapsedSettings)
        addSubview(collapsedBar)

        [headerStatus, headerREC, statusText, recordButton, settingsButton,
         heardLabel, heardValue, intentChip, answerLabel].forEach { expandedContent.addSubview($0) }
        addSubview(expandedContent)
        expandedContent.alphaValue = 0

        morph.onChange = { [weak self] _ in self?.applyLayout() }
    }

    private func observe() {
        // Any model change → refresh content + re-evaluate the morph after @Published commits.
        model.objectWillChange
            .sink { [weak self] in DispatchQueue.main.async { self?.refresh() } }
            .store(in: &cancellables)
        // Language flip → restring everything.
        AppLanguageStore.shared.objectWillChange
            .sink { [weak self] in DispatchQueue.main.async { self?.refresh() } }
            .store(in: &cancellables)
    }

    // MARK: Refresh (content from model)

    private func refresh() {
        let s = AppStrings.current

        let activity = model.answer.count / 12
        for mark in [collapsedStatus, headerStatus] {
            mark.status = model.status
            mark.recording = model.recording
            mark.activity = activity
        }

        collapsedREC.isHidden = !model.recording
        headerREC.isHidden = !model.recording

        statusText.stringValue = s.notchStatus(model.message)

        recordButton.update(systemName: model.recording ? "stop.fill" : "record.circle",
                            tint: model.recording ? NotchPalette.recording : NotchPalette.secondary,
                            label: model.recording ? s.stopRecording : s.startRecording)
        collapsedSettings.toolTip = s.settings
        settingsButton.toolTip = s.settings

        heardLabel.stringValue = s.heardLabel
        heardValue.stringValue = model.question
        intentChip.text = model.intentLabel

        let display = NotchPresentation.text(answer: model.answer, message: model.message,
                                             errorDetail: model.errorDetail, strings: s)
        answerLabel.attributedStringValue = NotchType.answerString(display, empty: model.answer.isEmpty)

        // Drive the morph from the model's expand state.
        if model.expanded != wasExpanded {
            wasExpanded = model.expanded
            if reduceMotion { morph.set(model.expanded ? 1 : 0) }
            else { morph.animate(to: model.expanded ? 1 : 0, duration: NotchPalette.morphDuration) }
        }
        applyLayout()
    }

    // MARK: Layout (morph-driven)

    override func layout() {
        super.layout()
        applyLayout()
    }

    private func applyLayout() {
        let b = bounds
        guard b.width > 1 else { return }
        let p = max(0, min(1, morph.value))

        // Card inset: the transparent shadow margin grows in only as we expand (top stays flush).
        let mH = NotchMetrics.shadowMarginH * p
        let mB = NotchMetrics.shadowMarginBottom * p
        let card = CGRect(x: mH, y: 0, width: b.width - mH * 2, height: b.height - mB)

        surface.frame = b
        surface.cardRect = card
        surface.topRadius = notchLerp(8, 11, p)
        surface.bottomRadius = notchLerp(11, 22, p)
        surface.depth = p
        surface.showShadow = p > 0.001

        collapsedBar.frame = card
        expandedContent.frame = card
        collapsedBar.alphaValue = 1 - p
        expandedContent.alphaValue = p
        collapsedBar.isHidden = p >= 0.999
        expandedContent.isHidden = p <= 0.001

        if !collapsedBar.isHidden { layoutCollapsed(card.size) }
        if !expandedContent.isHidden { layoutExpanded(card.size) }
    }

    private func layoutCollapsed(_ size: CGSize) {
        let h = size.height
        let cy = h / 2

        let rightReserve: CGFloat = 28 + 10 // settings button + trailing pad
        recordHit.frame = CGRect(x: 0, y: 0, width: max(0, size.width - rightReserve), height: h)

        collapsedStatus.frame = CGRect(x: 12, y: cy - 8, width: 16, height: 16)
        collapsedREC.sizeToFit() // fits text + cell insets + kern (intrinsicContentSize unders-counts)
        let recSize = collapsedREC.frame.size
        collapsedREC.frame = CGRect(x: 12 + 16 + 5, y: cy - recSize.height / 2,
                                    width: recSize.width, height: recSize.height)

        collapsedSettings.frame = CGRect(x: size.width - 28 - 10, y: cy - 12, width: 28, height: 24)
        collapsedSettings.alphaValue = hovering ? 1 : 0.55
    }

    private func layoutExpanded(_ size: CGSize) {
        // Header row.
        let headerTop: CGFloat = 9
        let rowH: CGFloat = 24
        let rowCY = headerTop + rowH / 2

        let settingsX = size.width - 18 - 28
        let recordX = settingsX - 28 - 4
        settingsButton.frame = CGRect(x: settingsX, y: rowCY - 12, width: 28, height: 24)
        recordButton.frame = CGRect(x: recordX, y: rowCY - 12, width: 28, height: 24)

        headerStatus.frame = CGRect(x: 18, y: rowCY - 8, width: 16, height: 16)
        var cursor: CGFloat = 18 + 16 + 8
        if !headerREC.isHidden {
            headerREC.sizeToFit()
            let recSize = headerREC.frame.size
            headerREC.frame = CGRect(x: cursor, y: rowCY - recSize.height / 2, width: recSize.width, height: recSize.height)
            cursor += recSize.width + 8
        }
        let textW = max(0, recordX - 12 - cursor)
        let textH = statusText.intrinsicContentSize.height
        statusText.frame = CGRect(x: cursor, y: rowCY - textH / 2, width: textW, height: textH)

        // Body.
        let contentX: CGFloat = 20
        let contentW = size.width - 40
        var y = headerTop + rowH + 8 + (model.answer.isEmpty ? 0 : 3)

        if !model.question.isEmpty {
            heardLabel.isHidden = false
            heardValue.isHidden = false
            heardLabel.sizeToFit()
            let labelW = heardLabel.frame.width
            let labelH = heardLabel.frame.height
            heardLabel.frame = CGRect(x: contentX, y: y, width: labelW, height: labelH)
            let valueX = contentX + labelW + 6
            let valueW = max(0, contentW - labelW - 6)
            let valueH = min(measuredHeight(heardValue, width: valueW), 34) // ≤ 2 lines
            heardValue.frame = CGRect(x: valueX, y: y, width: valueW, height: valueH)
            y += max(labelH, valueH) + 8
        } else {
            heardLabel.isHidden = true
            heardValue.isHidden = true
        }

        if !model.intentLabel.isEmpty {
            intentChip.isHidden = false
            let chipSize = intentChip.intrinsicContentSize
            intentChip.frame = CGRect(x: contentX, y: y, width: chipSize.width, height: chipSize.height)
            y += chipSize.height + 8
        } else {
            intentChip.isHidden = true
        }

        let answerH = NotchType.answerHeight(answerLabel.attributedStringValue.string,
                                             empty: model.answer.isEmpty, width: contentW)
        answerLabel.frame = CGRect(x: contentX, y: y, width: contentW, height: answerH)
    }

    private func measuredHeight(_ field: NSTextField, width: CGFloat) -> CGFloat {
        guard width > 1 else { return 0 }
        let attr = field.attributedStringValue
        return ceil(attr.boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
                                      options: [.usesLineFragmentOrigin, .usesFontLeading]).height)
    }

    // MARK: Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingAreaRef { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        trackingAreaRef = t
    }

    override func mouseEntered(with event: NSEvent) { setHovering(true) }
    override func mouseExited(with event: NSEvent) { setHovering(false) }

    private func setHovering(_ on: Bool) {
        guard hovering != on else { return }
        hovering = on
        onHover(on)
        NSAnimationContext.runAnimationGroup { c in
            c.duration = NotchPalette.controlDuration
            collapsedSettings.animator().alphaValue = (on ? 1 : 0.55)
        }
    }

    // MARK: Factories

    private static func makeLabel(size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSTextField {
        let f = NSTextField(labelWithString: "")
        f.font = .systemFont(ofSize: size, weight: weight)
        f.textColor = color
        f.backgroundColor = .clear
        f.drawsBackground = false
        f.isBordered = false
        f.isEditable = false
        f.lineBreakMode = .byTruncatingTail
        f.cell?.truncatesLastVisibleLine = true
        return f
    }

    private static func makeRECLabel() -> NSTextField {
        let f = makeLabel(size: 8.5, weight: .bold, color: NotchPalette.recording)
        f.lineBreakMode = .byClipping
        f.cell?.truncatesLastVisibleLine = false
        f.attributedStringValue = NSAttributedString(string: "REC", attributes: [
            .font: NSFont.systemFont(ofSize: 8.5, weight: .bold),
            .foregroundColor: NotchPalette.recording,
            .kern: 0.6,
        ])
        return f
    }
}

// MARK: - Containers

/// A top-left-origin container so child frames laid out with `y` growing downward match the
/// flipped `NotchView` (a plain NSView is bottom-left, which would invert the stacked rows).
private final class FlippedContainer: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - Collapsed record hit-area

/// Captures clicks anywhere in the collapsed bar's left region (status + REC) and toggles
/// recording, regardless of which decorative child is under the cursor. First-mouse so it works
/// inside the non-activating panel without first focusing the app.
private final class RecordHitView: NSView {
    var onClick: (() -> Void)?
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return bounds.contains(local) ? self : nil
    }
    override func mouseDown(with event: NSEvent) {}   // swallow; act on up-inside
    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if bounds.contains(p) { onClick?() }
    }
}

// MARK: - Intent chip

/// The matched/predicted intent as a quiet accent tag — a glance-check that the notch
/// understood the question. A soft brand-tinted capsule, never a hard pill.
private final class IntentChipView: NSView {
    private let label = NSTextField(labelWithString: "")
    var text: String = "" {
        didSet {
            label.attributedStringValue = NSAttributedString(string: text, attributes: [
                .font: NSFont.systemFont(ofSize: 10.5, weight: .semibold),
                .foregroundColor: NotchPalette.accentHi,
                .kern: 0.2,
            ])
            invalidateIntrinsicContentSize()
            needsLayout = true
            needsDisplay = true
        }
    }

    private let hPad: CGFloat = 8
    private let vPad: CGFloat = 3

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.backgroundColor = .clear
        label.drawsBackground = false
        label.isBordered = false
        label.isEditable = false
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        let s = label.intrinsicContentSize
        return NSSize(width: ceil(s.width) + hPad * 2 + 2, height: ceil(s.height) + vPad * 2)
    }

    override func layout() {
        super.layout()
        let s = label.intrinsicContentSize
        label.frame = CGRect(x: hPad, y: (bounds.height - s.height) / 2, width: bounds.width - hPad * 2, height: s.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds
        let radius = r.height / 2
        let cap = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        NotchPalette.accent.withAlphaComponent(0.14).setFill(); cap.fill()
        cap.lineWidth = 0.75
        NotchPalette.accent.withAlphaComponent(0.22).setStroke(); cap.stroke()
    }
}
