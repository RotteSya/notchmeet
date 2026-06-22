import AppKit
import QuartzCore

/// The status jewel — the small instrument shared by the collapsed bar and the expanded
/// header. Recording is always the outer red ring; the inner mark conveys pipeline state
/// without relying on colour alone, and every state crossfades into the next so the notch
/// never blinks between symbols. Continuous motion runs on a `CADisplayLink` clock so it stays
/// smooth regardless of state churn during streaming. Drawn entirely with Core Graphics.
final class NotchStatusMark: NSView {
    var status: AnswerModel.Status = .ready {
        didSet { if status != oldValue { prevStatus = oldValue; statusChangedAt = CACurrentMediaTime(); needsDisplay = true } }
    }
    var recording: Bool = false {
        didSet { if recording != oldValue { recordingWasOn = oldValue; recordingChangedAt = CACurrentMediaTime(); needsDisplay = true } }
    }
    var activity: Int = 0   // kept for call-site parity; motion is time-driven

    private var prevStatus: AnswerModel.Status = .ready
    private var statusChangedAt: CFTimeInterval = -10
    private var recordingChangedAt: CFTimeInterval = -10
    private var recordingWasOn = false
    private var link: CADisplayLink?

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    private lazy var checkImage = notchTintedSymbol("checkmark", pointSize: 8, weight: .bold, color: NotchPalette.accent)
    private lazy var bangImage  = notchTintedSymbol("exclamationmark", pointSize: 8.5, weight: .bold, color: NotchPalette.warning)

    override init(frame frameRect: NSRect) { super.init(frame: frameRect) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 16, height: 16) }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    // MARK: Display clock — runs only while on screen (and motion is allowed)

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { startLink() } else { stopLink() }
    }

    private func startLink() {
        guard link == nil, !reduceMotion else { return }
        let l = displayLink(target: self, selector: #selector(tick))
        l.add(to: .main, forMode: .common)
        link = l
    }

    private func stopLink() { link?.invalidate(); link = nil }
    @objc private func tick() { needsDisplay = true }
    deinit { link?.invalidate() }

    // MARK: Draw

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let t = CACurrentMediaTime()
        let center = CGPoint(x: bounds.midX, y: bounds.midY)

        // Recording ring — quick fade in/out so toggling REC never pops.
        let rp = reduceMotion ? 1 : clamp01((t - recordingChangedAt) / NotchPalette.contentDuration)
        let ringAlpha: CGFloat = recording ? rp : (recordingWasOn ? (1 - rp) : 0)
        if ringAlpha > 0.001 { drawRecordingRing(ctx, center: center, alpha: ringAlpha) }

        // Status core crossfade: old shrinks/fades out, new grows/fades in.
        let sp = reduceMotion ? 1 : clamp01((t - statusChangedAt) / NotchPalette.contentDuration)
        if sp < 1 {
            drawCore(prevStatus, ctx: ctx, center: center, t: t,
                     alpha: 1 - sp, scale: notchLerp(1, 0.55, sp))
        }
        drawCore(status, ctx: ctx, center: center, t: t,
                 alpha: sp, scale: notchLerp(0.55, 1, sp))
    }

    private func clamp01(_ v: CFTimeInterval) -> CGFloat { CGFloat(min(1, max(0, v))) }

    private func drawCore(_ s: AnswerModel.Status, ctx: CGContext, center: CGPoint,
                          t: CFTimeInterval, alpha: CGFloat, scale: CGFloat) {
        if alpha <= 0.001 { return }
        ctx.saveGState()
        ctx.translateBy(x: center.x, y: center.y)
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -center.x, y: -center.y)
        switch s {
        case .ready:
            drawBreathingDot(ctx, center: center, t: t, color: NotchPalette.tertiary,
                             size: 4.5, range: 0.10, speed: 0.7, alpha: alpha)
        case .listening:
            drawBreathingDot(ctx, center: center, t: t, color: NotchPalette.recording,
                             size: 6, range: 0.34, speed: 1.5, alpha: alpha)
        case .thinking:
            drawSpinner(ctx, center: center, t: t, color: NotchPalette.accent, alpha: alpha)
        case .streaming:
            drawEqualizer(ctx, center: center, t: t, color: NotchPalette.accent, alpha: alpha)
        case .presenting:
            drawSymbol(checkImage, center: center, alpha: alpha)
        case .error:
            drawSymbol(bangImage, center: center, alpha: alpha)
        }
        ctx.restoreGState()
    }

    // MARK: Cores

    private func drawRecordingRing(_ ctx: CGContext, center: CGPoint, alpha: CGFloat) {
        let d: CGFloat = 14, r = d / 2
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 2.5,
                      color: NotchPalette.recording.withAlphaComponent(0.55 * alpha).cgColor)
        ctx.setStrokeColor(NotchPalette.recording.withAlphaComponent(0.92 * alpha).cgColor)
        ctx.setLineWidth(1.2)
        ctx.strokeEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: d, height: d))
        ctx.restoreGState()
    }

    private func drawBreathingDot(_ ctx: CGContext, center: CGPoint, t: CFTimeInterval,
                                  color: NSColor, size: CGFloat, range: Double, speed: Double, alpha: CGFloat) {
        let wave = (sin(t * speed * 2 * .pi) + 1) / 2                 // 0…1
        let sc = reduceMotion ? 1 : 1 + (CGFloat(wave) - 0.5) * 2 * CGFloat(range)
        let a  = reduceMotion ? 1 : (0.74 + 0.26 * CGFloat(wave))
        let d = size * sc
        ctx.setFillColor(color.withAlphaComponent(color.alphaComponent * a * alpha).cgColor)
        ctx.fillEllipse(in: CGRect(x: center.x - d / 2, y: center.y - d / 2, width: d, height: d))
    }

    private func drawSpinner(_ ctx: CGContext, center: CGPoint, t: CFTimeInterval, color: NSColor, alpha: CGFloat) {
        let d: CGFloat = 10.5, r = d / 2
        ctx.setLineWidth(1.6)
        ctx.setStrokeColor(color.withAlphaComponent(0.16 * alpha).cgColor)
        ctx.strokeEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: d, height: d))

        let angle = reduceMotion ? 0 : (t.truncatingRemainder(dividingBy: 1.1) / 1.1) * 2 * .pi
        let start = -CGFloat.pi / 2 + CGFloat(angle)
        ctx.setStrokeColor(color.withAlphaComponent(alpha).cgColor)
        ctx.setLineCap(.round)
        ctx.addArc(center: center, radius: r, startAngle: start, endAngle: start + 0.30 * 2 * .pi, clockwise: false)
        ctx.strokePath()
    }

    private func drawEqualizer(_ ctx: CGContext, center: CGPoint, t: CFTimeInterval, color: NSColor, alpha: CGFloat) {
        let phases: [Double] = [0.0, 0.66, 1.32]
        let barW: CGFloat = 2, gap: CGFloat = 1.6
        let totalW = barW * 3 + gap * 2
        var x = center.x - totalW / 2
        color.withAlphaComponent(alpha).setFill()
        for i in 0..<3 {
            let wave = (sin(t * 6 + phases[i]) + 1) / 2
            let h = CGFloat(reduceMotion ? 7.0 : 3.5 + wave * 7.0)
            let rect = CGRect(x: x, y: center.y - h / 2, width: barW, height: h)
            NSBezierPath(roundedRect: rect, xRadius: barW / 2, yRadius: barW / 2).fill()
            x += barW + gap
        }
    }

    private func drawSymbol(_ image: NSImage?, center: CGPoint, alpha: CGFloat) {
        guard let image else { return }
        let s = image.size
        image.draw(in: CGRect(x: center.x - s.width / 2, y: center.y - s.height / 2, width: s.width, height: s.height),
                   from: .zero, operation: .sourceOver, fraction: alpha)
    }
}
