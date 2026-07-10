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
    // Interior light field (Metal) — the obsidian's living light, between body and content.
    private let luma = NotchLumaView()

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
    private let creditChip = CreditChipView()
    /// Empty-state runtime message only（正文答案交给 `answerStream` 逐字诞生）。
    private let answerLabel: NSTextField = {
        let f = NotchView.makeLabel(size: 15, weight: .regular, color: NotchPalette.primary)
        f.isSelectable = true
        f.maximumNumberOfLines = 0
        f.lineBreakMode = .byWordWrapping
        f.cell?.wraps = true
        return f
    }()
    private let answerStream = StreamingAnswerView()

    private lazy var morph = DisplayTween(host: self, value: 0)
    /// 几何专用的第二条 morph 通道：展开方向带弹簧过冲（圆角/内缩微微越过再落定），
    /// 而 `morph` 继续用 out-cubic 驱动透明度交叉淡化——透明度过冲会让内容在
    /// 中途的小卡片里提前全亮并溢出，所以两通道必须分离。
    private lazy var geoMorph = DisplayTween(host: self, value: 0)
    /// 新一轮问答的入场（0→1）：问题/意图行淡入 + 6pt 上浮，与答案的逐字诞生同拍。
    private lazy var introTween = DisplayTween(host: self, value: 1)
    /// 状态文字交叉淡化（0→0.5 旧字淡出，0.5→1 新字淡入），杜绝生硬换字。
    private lazy var statusSwap = DisplayTween(host: self, value: 1)
    private var displayedStatusText = ""
    private var pendingStatusText = ""
    private var lastQuestion = ""
    private var lastAnswerCount = 0
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
        addSubview(luma)

        recordHit.onClick = { [weak self] in self?.onToggleRecording() }
        recordHit.addSubview(collapsedStatus)
        recordHit.addSubview(collapsedREC)
        collapsedBar.addSubview(recordHit)
        collapsedBar.addSubview(collapsedSettings)
        addSubview(collapsedBar)

        [headerStatus, headerREC, statusText, creditChip, recordButton, settingsButton,
         heardLabel, heardValue, intentChip, answerLabel, answerStream].forEach { expandedContent.addSubview($0) }
        addSubview(expandedContent)
        expandedContent.alphaValue = 0

        morph.onChange = { [weak self] _ in self?.applyLayout() }
        geoMorph.onChange = { [weak self] _ in self?.applyLayout() }
        introTween.onChange = { [weak self] _ in self?.applyLayout() }
        statusSwap.onChange = { [weak self] v in self?.applyStatusSwap(v) }
    }

    /// 交叉淡化的换字点在中点：v<0.5 旧字淡出，v≥0.5 换新字淡入。
    private func applyStatusSwap(_ v: CGFloat) {
        if v >= 0.5, displayedStatusText != pendingStatusText {
            displayedStatusText = pendingStatusText
            statusText.stringValue = displayedStatusText
        }
        statusText.alphaValue = abs(v * 2 - 1)
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
        luma.setState(model.status, recording: model.recording)

        collapsedREC.isHidden = !model.recording
        headerREC.isHidden = !model.recording

        // 状态文字：交叉淡化换字，不生硬跳变。
        let newStatus = s.notchStatus(model.message)
        if newStatus != displayedStatusText && newStatus != pendingStatusText {
            pendingStatusText = newStatus
            if reduceMotion || displayedStatusText.isEmpty {
                statusSwap.set(1)
                displayedStatusText = newStatus
                statusText.stringValue = newStatus
                statusText.alphaValue = 1
            } else {
                statusSwap.set(0)
                statusSwap.animate(to: 1, duration: 0.24)
            }
        }

        recordButton.update(systemName: model.recording ? "stop.fill" : "record.circle",
                            tint: model.recording ? NotchPalette.recording : NotchPalette.secondary,
                            label: model.recording ? s.stopRecording : s.startRecording)
        collapsedSettings.toolTip = s.settings
        settingsButton.toolTip = s.settings

        heardLabel.stringValue = s.heardLabel
        heardValue.stringValue = model.question
        intentChip.text = model.intentLabel
        creditChip.update(seconds: model.creditSeconds, strings: s)

        // 新一轮问答（识别出的问题变了）→ 问题/意图行入场动效，与答案逐字诞生同拍。
        if model.question != lastQuestion {
            let entering = !model.question.isEmpty
            lastQuestion = model.question
            if entering {
                if reduceMotion { introTween.set(1) }
                else { introTween.set(0); introTween.animate(to: 1, duration: 0.34) }
            }
        }

        let display = NotchPresentation.text(answer: model.answer, message: model.message,
                                             errorDetail: model.errorDetail, strings: s)
        if model.answer.isEmpty {
            answerLabel.isHidden = false
            answerStream.isHidden = true
            answerStream.setText("")
            answerLabel.attributedStringValue = NotchType.answerString(display, empty: true)
        } else {
            answerLabel.isHidden = true
            answerStream.isHidden = false
            answerStream.setText(display)
            // token 到达 → 光场里过一道涟漪（只在流式阶段，别的状态不闪）。
            if model.status == .streaming, display.count > lastAnswerCount { luma.pulse() }
        }
        lastAnswerCount = display.count
        // 新しいターンの考え中、まだ前の答えを表示している間は薄く見せて「次が来る」ことを示す。
        answerStream.dimmed = model.status == .thinking && !model.answer.isEmpty

        // Drive the morph from the model's expand state. 透明度通道（morph）恒为
        // out-cubic；几何通道（geoMorph）展开时弹簧轻过冲、收起时同样安静收拢。
        if model.expanded != wasExpanded {
            wasExpanded = model.expanded
            let target: CGFloat = model.expanded ? 1 : 0
            if reduceMotion {
                morph.set(target)
                geoMorph.set(target)
            } else {
                morph.animate(to: target, duration: NotchPalette.morphDuration)
                geoMorph.ease = model.expanded ? NotchMotion.springSettle : NotchMotion.outCubic
                geoMorph.animate(to: target, duration: NotchPalette.morphDuration)
            }
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
        // p：透明度/可见性通道，钳位（交叉淡化不可反相）。
        // g：几何通道，允许弹簧过冲——过冲时卡片向内轻收 ~2pt、圆角明显变软再落定，
        //    整块石板像软体一样着陆。圆角把过冲分量放大 2.5×（否则 10% 过冲在 11pt
        //    的圆角差上只有半个点，感受不到）；内缩保持原幅度，窗口从不超出最终边界。
        let p = max(0, min(1, morph.value))
        let g = max(0, geoMorph.value)
        let gr = g <= 1 ? g : 1 + (g - 1) * 2.5   // radii-only amplified settle

        // Card inset: the transparent shadow margin grows in only as we expand (top stays flush).
        let mH = NotchMetrics.shadowMarginH * g
        let mB = NotchMetrics.shadowMarginBottom * g
        let card = CGRect(x: mH, y: 0, width: b.width - mH * 2, height: b.height - mB)

        surface.frame = b
        surface.cardRect = card
        surface.topRadius = notchLerp(8, 11, gr)
        surface.bottomRadius = notchLerp(11, 22, gr)
        surface.depth = p
        surface.showShadow = p > 0.001

        luma.frame = b
        luma.setSlab(cardRect: card, topRadius: notchLerp(8, 11, gr),
                     bottomRadius: notchLerp(11, 22, gr), depth: p)

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

        // 额度胶囊：紧贴录音键左侧。计量中常显，安静不抢戏；额度紧张时自己变色。
        var leftLimit = recordX
        if !creditChip.isHidden {
            let chipSize = creditChip.intrinsicContentSize
            let chipX = recordX - 8 - chipSize.width
            creditChip.frame = CGRect(x: chipX, y: rowCY - chipSize.height / 2,
                                      width: chipSize.width, height: chipSize.height)
            leftLimit = chipX
        }

        headerStatus.frame = CGRect(x: 18, y: rowCY - 8, width: 16, height: 16)
        var cursor: CGFloat = 18 + 16 + 8
        if !headerREC.isHidden {
            headerREC.sizeToFit()
            let recSize = headerREC.frame.size
            headerREC.frame = CGRect(x: cursor, y: rowCY - recSize.height / 2, width: recSize.width, height: recSize.height)
            cursor += recSize.width + 8
        }
        let textW = max(0, leftLimit - 12 - cursor)
        let textH = statusText.intrinsicContentSize.height
        statusText.frame = CGRect(x: cursor, y: rowCY - textH / 2, width: textW, height: textH)

        // Body.
        let contentX: CGFloat = 20
        let contentW = size.width - 40
        var y = headerTop + rowH + 8 + (model.answer.isEmpty ? 0 : 3)

        // 新一轮入场：问题/意图行淡入 + 从下方 6pt 浮定（答案由逐字诞生自带入场）。
        let intro = max(0, min(1, introTween.value))
        let introDy = (1 - intro) * 6

        if !model.question.isEmpty {
            heardLabel.isHidden = false
            heardValue.isHidden = false
            heardLabel.alphaValue = intro
            heardValue.alphaValue = intro
            heardLabel.sizeToFit()
            let labelW = heardLabel.frame.width
            let labelH = heardLabel.frame.height
            heardLabel.frame = CGRect(x: contentX, y: y + introDy, width: labelW, height: labelH)
            let valueX = contentX + labelW + 6
            let valueW = max(0, contentW - labelW - 6)
            let valueH = min(measuredHeight(heardValue, width: valueW), 34) // ≤ 2 lines
            heardValue.frame = CGRect(x: valueX, y: y + introDy, width: valueW, height: valueH)
            y += max(labelH, valueH) + 8
        } else {
            heardLabel.isHidden = true
            heardValue.isHidden = true
        }

        if !model.intentLabel.isEmpty {
            intentChip.isHidden = false
            intentChip.alphaValue = intro
            let chipSize = intentChip.intrinsicContentSize
            intentChip.frame = CGRect(x: contentX, y: y + introDy * 1.4, width: chipSize.width, height: chipSize.height)
            y += chipSize.height + 8
        } else {
            intentChip.isHidden = true
        }

        let display = model.answer.isEmpty ? answerLabel.attributedStringValue.string
                                           : lastQuestionAnswerText()
        let answerH = NotchType.answerHeight(display, empty: model.answer.isEmpty, width: contentW)
        let answerFrame = CGRect(x: contentX, y: y, width: contentW, height: answerH)
        answerLabel.frame = answerFrame
        answerStream.frame = answerFrame
    }

    /// The exact string the stream view renders（与 refresh 里传给 setText 的同源）。
    private func lastQuestionAnswerText() -> String {
        NotchPresentation.text(answer: model.answer, message: model.message,
                               errorDetail: model.errorDetail, strings: AppStrings.current)
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

// MARK: - Credit chip

/// 计量会话中的剩余额度：与 IntentChip 同族的安静胶囊，坐在录音键左侧。
/// 余量充足时中性灰、只报分钟；≤10 分钟转琥珀并切到 mm:ss 实时倒计时；≤3 分钟转红。
/// 颜色即信息——不闪不跳，紧张感全部交给色彩和秒针。
final class CreditChipView: NSView {
    private let label = NSTextField(labelWithString: "")
    private var tint: NSColor = NotchPalette.secondary

    private let hPad: CGFloat = 8
    private let vPad: CGFloat = 3

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.backgroundColor = .clear
        label.drawsBackground = false
        label.isBordered = false
        label.isEditable = false
        label.lineBreakMode = .byClipping
        addSubview(label)
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    func update(seconds: Int?, strings: AppStrings) {
        guard let seconds else {
            if !isHidden { isHidden = true }
            return
        }
        isHidden = false
        let urgent = seconds <= 600
        tint = seconds <= 180 ? NotchPalette.recording
             : (urgent ? NotchPalette.warning : NotchPalette.secondary)
        let text = urgent ? strings.creditCountdown(seconds) : strings.creditMinutes(seconds)
        label.attributedStringValue = NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold),
            .foregroundColor: tint,
            .kern: 0.2,
        ])
        toolTip = "\(strings.creditRemainingLabel) \(strings.creditMinutes(seconds))"
        invalidateIntrinsicContentSize()
        needsLayout = true
        needsDisplay = true
    }

    private var labelSize: NSSize { label.cell?.cellSize ?? label.intrinsicContentSize }

    override var intrinsicContentSize: NSSize {
        let s = labelSize
        return NSSize(width: ceil(s.width) + hPad * 2, height: ceil(s.height) + vPad * 2)
    }

    override func layout() {
        super.layout()
        let s = labelSize
        label.frame = CGRect(x: hPad, y: (bounds.height - s.height) / 2,
                             width: bounds.width - hPad * 2, height: s.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds
        let radius = r.height / 2
        let cap = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        tint.withAlphaComponent(0.12).setFill(); cap.fill()
        cap.lineWidth = 0.75
        tint.withAlphaComponent(0.22).setStroke(); cap.stroke()
    }
}

// MARK: - Intent chip

/// The matched/predicted intent as a quiet accent tag — a glance-check that the notch
/// understood the question. A soft brand-tinted capsule, never a hard pill.
final class IntentChipView: NSView {
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

    /// Size from the cell, not intrinsicContentSize: the field's intrinsic width omits the
    /// cell insets (自己紹介: intrinsic 43.0 vs cellSize 46.6), so the last glyph clipped.
    private var labelSize: NSSize { label.cell?.cellSize ?? label.intrinsicContentSize }

    override var intrinsicContentSize: NSSize {
        let s = labelSize
        return NSSize(width: ceil(s.width) + hPad * 2, height: ceil(s.height) + vPad * 2)
    }

    override func layout() {
        super.layout()
        let s = labelSize
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
