import AppKit
import QuartzCore

// The notch design system. The notch is a single piece of machined obsidian that *lives*
// in the physical cutout and grows out of it. Collapsed, it is indistinguishable from the
// hardware notch (pure black at the top edge, so the two fuse). Expanded, its lower face
// catches a whisper of the screen's light along a hairline edge, with a faint internal
// volume — never a flat black decal. Every value here exists to kill a "generic" tell:
// flat fills, banded gradients, hard rectangles, snapping motion.
//
// Pure AppKit: the slab is drawn with Core Graphics inside a flipped `NotchSurfaceView`,
// so geometry math stays top-left (y down) exactly as the SwiftUI `Shape` was authored.

// MARK: - Palette

enum NotchPalette {
    /// Pure black at the seam so the slab fuses with the physical notch; volume is added by
    /// `NotchSurfaceView`, not by lightening this base.
    static let background = NSColor.black

    static let primary   = NSColor(white: 1, alpha: 0.96)
    static let secondary = NSColor(white: 1, alpha: 0.60)
    static let tertiary  = NSColor(white: 1, alpha: 0.34)

    /// Brand periwinkle, unified with onboarding so the product reads as one designed thing.
    /// A hi/lo pair drives the live "thinking / streaming" cues.
    static let accent    = NSColor(srgbRed: 0.471, green: 0.612, blue: 1.000, alpha: 1) // #78A0FF
    static let accentHi  = NSColor(srgbRed: 0.639, green: 0.745, blue: 1.000, alpha: 1) // #A3BEFF
    static let accentLo  = NSColor(srgbRed: 0.345, green: 0.470, blue: 0.910, alpha: 1) // grounded edge

    /// Apple system red / orange, for the unmistakable recording + warning treatments.
    static let recording = NSColor(srgbRed: 1.000, green: 0.271, blue: 0.227, alpha: 1) // #FF453A
    static let warning   = NSColor(srgbRed: 1.000, green: 0.624, blue: 0.118, alpha: 1) // #FF9F1E

    /// Cool, near-white with a breath of brand blue — the colour of screen light on glass,
    /// used for the obsidian's lower-face sheen.
    static let sheen     = NSColor(srgbRed: 0.80, green: 0.86, blue: 1.00, alpha: 1)

    static let rule      = NSColor(white: 1, alpha: 0.10)

    // Motion durations (s). The single morph time is shared by the controller's panel-frame
    // animation and the view's radius/content tween so the whole instrument moves as one body.
    static let morphDuration: CFTimeInterval = {
        #if DEBUG
        // 视觉 QA：FI_SLOW_MORPH=1 把 morph 放慢到 2.4s，便于连拍逐帧检查过冲曲线。
        if ProcessInfo.processInfo.environment["FI_SLOW_MORPH"] == "1" { return 2.4 }
        #endif
        return 0.42
    }()
    static let contentDuration: CFTimeInterval = 0.18
    static let controlDuration: CFTimeInterval = 0.13
}

/// Shared easing curves.
enum NotchMotion {
    /// 展开方向的欠阻尼弹簧响应：一次 ~10% 的轻过冲后柔性落定（t=1 残差 <0.6%，
    /// tween 结束时 snap 到位，肉眼不可见）。只用于**展开**——收起是安静的呼气，
    /// 弹跳会显得轻浮，维持原 out-cubic。
    static func springSettle(_ t: CGFloat) -> CGFloat {
        1 - exp(-5.0 * t) * cos(7.0 * t)
    }

    /// 原 morph 曲线（收起方向沿用）。
    static func outCubic(_ t: CGFloat) -> CGFloat { 1 - pow(1 - t, 3) }
}

/// Layout metrics shared between the controller (panel frame) and the view (content inset),
/// so the transparent margin that lets the expanded card cast a soft shadow stays in sync on
/// both sides. The margin is applied **only when expanded** — collapsed keeps its exact
/// menu-bar geometry, so nothing transparent ever overhangs the menu bar.
enum NotchMetrics {
    static let shadowMarginH: CGFloat = 22       // each side
    static let shadowMarginBottom: CGFloat = 28
}

// MARK: - Small helpers

@inline(__always) func notchLerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }

/// A vertical CGGradient from `(color, location)` stops in sRGB.
func notchGradient(_ stops: [(NSColor, CGFloat)]) -> CGGradient {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let colors = stops.map { ($0.0.usingColorSpace(.sRGB) ?? $0.0).cgColor } as CFArray
    let locations = stops.map { $0.1 }
    return CGGradient(colorsSpace: space, colors: colors, locations: locations)!
}

/// A solid-tinted copy of an SF Symbol (template images don't tint when drawn into an
/// arbitrary CGContext, so bake the colour in once).
func notchTintedSymbol(_ name: String, pointSize: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSImage? {
    let cfg = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
    guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(cfg) else { return nil }
    let size = base.size
    let img = NSImage(size: size)
    img.lockFocus()
    color.set()
    let r = NSRect(origin: .zero, size: size)
    base.draw(in: r)
    r.fill(using: .sourceAtop)
    img.unlockFocus()
    img.isTemplate = false
    return img
}

// MARK: - Text

/// Single source of truth for the answer's typography, used by BOTH the view (rendering) and
/// the controller (height measurement), so the measured panel height always matches what is
/// drawn — no one-line drift that would clip the last line or leave a gap.
enum NotchType {
    static func answerString(_ text: String, empty: Bool) -> NSAttributedString {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = empty ? 2 : 3
        // 正文字号跟随用户设置（设置 → 通用 → 回答字号）；空态提示固定小号。
        let font = NSFont.systemFont(ofSize: empty ? 13 : Settings.answerTextSize.points)
        return NSAttributedString(string: text, attributes: [
            .font: font,
            .paragraphStyle: p,
            .foregroundColor: empty ? NotchPalette.secondary : NotchPalette.primary,
        ])
    }

    /// Measure with a real NSTextField cell — NOT `boundingRect`: the field's cell wraps a
    /// couple of points earlier than the raw text measurement, so long answers came out one
    /// line short (last line truncated to "…" while the card showed slack below). Main-thread
    /// only, same as both callers.
    private static let measurer: NSTextField = {
        let f = NSTextField(labelWithString: "")
        f.maximumNumberOfLines = 0
        f.lineBreakMode = .byWordWrapping
        f.cell?.wraps = true
        return f
    }()

    static func answerHeight(_ text: String, empty: Bool, width: CGFloat) -> CGFloat {
        // 非空答案由 StreamingAnswerView 用 CoreText 渲染 → 量高必须走同一个 framesetter。
        if !empty { return StreamingAnswerView.measure(text, width: width) }
        measurer.attributedStringValue = answerString(text, empty: empty)
        let bounds = NSRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude)
        let h = measurer.cell?.cellSize(forBounds: bounds).height
            ?? answerString(text, empty: empty).boundingRect(
                with: NSSize(width: width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading]).height
        return ceil(h)
    }
}

// MARK: - Display-link tween

/// A 0…1 (or arbitrary) value tweened over a duration on the display clock. Drives the morph
/// (radii + content crossfade) so it stays glued to the controller's panel-frame animation.
/// Uses a weak proxy as the display-link target to avoid a retain cycle.
final class DisplayTween {
    private(set) var value: CGFloat
    private var from: CGFloat = 0
    private var to: CGFloat = 0
    private var startTime: CFTimeInterval = 0
    private var duration: CFTimeInterval = NotchPalette.morphDuration
    private var link: CADisplayLink?
    private var proxy: TweenProxy?
    private weak var host: NSView?

    var onChange: ((CGFloat) -> Void)?
    /// Out-expo-ish settle, matched to the controller's frame curve (0.22, 0.90, 0.24, 1.0).
    var ease: (CGFloat) -> CGFloat = { t in 1 - pow(1 - t, 3) }

    init(host: NSView, value: CGFloat = 0) {
        self.host = host
        self.value = value
    }

    /// Jump to a value immediately (Reduce Motion).
    func set(_ v: CGFloat) {
        link?.isPaused = true
        value = v
        onChange?(v)
    }

    func animate(to target: CGFloat, duration: CFTimeInterval) {
        guard let host else { set(target); return }
        if value == target { return }
        from = value
        to = target
        self.duration = max(0.001, duration)
        startTime = CACurrentMediaTime()
        if link == nil {
            let p = TweenProxy(self)
            proxy = p
            link = host.displayLink(target: p, selector: #selector(TweenProxy.tick))
            link?.add(to: .main, forMode: .common)
        }
        link?.isPaused = false
    }

    fileprivate func step() {
        let elapsed = CACurrentMediaTime() - startTime
        let t = min(1, max(0, elapsed / duration))
        value = from + (to - from) * ease(CGFloat(t))
        onChange?(value)
        if t >= 1 {
            value = to
            onChange?(value)
            link?.isPaused = true
        }
    }

    deinit { link?.invalidate() }
}

private final class TweenProxy {
    weak var owner: DisplayTween?
    init(_ o: DisplayTween) { owner = o }
    @objc func tick() { owner?.step() }
}

// MARK: - Obsidian surface

/// The material treatment applied to the notch slab, drawn entirely within the shape so it
/// never spills outside the card: a near-black body that stays pure black at the seam and lifts
/// almost imperceptibly toward the lower face; a soft inner shadow seating it under the menu
/// bar; a cool specular hairline along the lower edge catching the screen's light; and a
/// triangular-noise dither that keeps the gradients glassy rather than stepped (the same
/// anti-banding device the onboarding aurora uses). Flipped so geometry is top-left (y down).
final class NotchSurfaceView: NSView {
    /// The rect (within `bounds`) the slab is drawn in. `bounds` is the full panel — including
    /// the transparent shadow margin — so the drop shadow has room to fall without clipping.
    var cardRect: CGRect = .zero { didSet { needsDisplay = true } }
    var topRadius: CGFloat = 8 { didSet { needsDisplay = true } }
    var bottomRadius: CGFloat = 11 { didSet { needsDisplay = true } }
    /// 0 = collapsed (seam-fused, minimal volume) … 1 = expanded (full lower-face volume).
    var depth: CGFloat = 0 { didSet { needsDisplay = true } }
    var showShadow: Bool = false { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil } // never intercept clicks

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, cardRect.width > 1 else { return }
        let rect = cardRect
        let path = NotchShape.cgPath(in: rect, topRadius: topRadius, bottomRadius: bottomRadius)

        // Grounded drop shadow (expanded only). Paint the opaque body twice with a CG shadow so
        // it falls below the card — a tight contact shadow plus a soft ambient one. Offsets are
        // positive-down because the flipped context has +y pointing toward the bottom of screen.
        if showShadow {
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: 9), blur: 16,
                          color: NSColor.black.withAlphaComponent(0.55).cgColor)
            ctx.addPath(path); ctx.setFillColor(NSColor.black.cgColor); ctx.fillPath()
            ctx.restoreGState()
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: 2), blur: 5,
                          color: NSColor.black.withAlphaComponent(0.38).cgColor)
            ctx.addPath(path); ctx.setFillColor(NSColor.black.cgColor); ctx.fillPath()
            ctx.restoreGState()
        }

        // Base fill.
        ctx.saveGState()
        ctx.addPath(path); ctx.setFillColor(NotchPalette.background.cgColor); ctx.fillPath()
        ctx.restoreGState()

        // Interior overlays, clipped to the slab.
        ctx.saveGState()
        ctx.addPath(path); ctx.clip()

        // bodyLight: a cool sheen reflecting the screen's light up onto the lower face — pure
        // black at the top seam, lifting to a graphite whisper below. Additive so it only lifts.
        ctx.saveGState()
        ctx.setBlendMode(.plusLighter)
        ctx.drawLinearGradient(
            notchGradient([
                (.clear, 0.0),
                (.clear, 0.24),
                (NotchPalette.sheen.withAlphaComponent(0.022 + 0.040 * depth), 1.0),
            ]),
            start: CGPoint(x: rect.midX, y: rect.minY),
            end: CGPoint(x: rect.midX, y: rect.maxY),
            options: []
        )
        ctx.restoreGState()

        // seamShadow: darken just under the top seam so the slab reads as tucked beneath the bar.
        ctx.drawLinearGradient(
            notchGradient([
                (NSColor.black.withAlphaComponent(0.55), 0.0),
                (.clear, 0.18),
                (.clear, 1.0),
            ]),
            start: CGPoint(x: rect.midX, y: rect.minY),
            end: CGPoint(x: rect.midX, y: rect.maxY),
            options: []
        )

        // dither: a fine static noise tile at very low opacity, additive, to break up banding.
        if let tile = NotchDither.tileImage {
            ctx.saveGState()
            ctx.setBlendMode(.plusLighter)
            ctx.setAlpha(0.025)
            ctx.draw(tile, in: CGRect(x: 0, y: 0, width: 96, height: 96), byTiling: true)
            ctx.restoreGState()
        }
        ctx.restoreGState() // end path clip

        // edgeLight: a cool specular hairline riding the lower edge — the screen's light on a
        // machined lip. Clip to the inner half of a thin stroke of the path so it reads as an
        // inset border (matching the old `strokeBorder`), fading out toward the fused seam.
        ctx.saveGState()
        ctx.addPath(path); ctx.clip()
        let stroked = path.copy(strokingWithWidth: 1.5, lineCap: CGLineCap.round, lineJoin: CGLineJoin.round, miterLimit: 10)
        ctx.addPath(stroked); ctx.clip()
        ctx.setBlendMode(.plusLighter)
        ctx.drawLinearGradient(
            notchGradient([
                (NSColor(white: 1, alpha: 0.0), 0.0),
                (NSColor(white: 1, alpha: 0.0), 0.40),
                (NotchPalette.accentHi.withAlphaComponent(0.12 + 0.11 * depth), 0.78),
                (NSColor(white: 1, alpha: 0.22 + 0.16 * depth), 1.0),
            ]),
            start: CGPoint(x: rect.midX, y: rect.minY),
            end: CGPoint(x: rect.midX, y: rect.maxY),
            options: []
        )
        ctx.restoreGState()
    }
}

// MARK: - Dither tile

/// A static, cached fine-noise tile (a CGImage, generated once and tiled). Triangular-PDF-ish
/// white noise — the same anti-banding device used across the product.
enum NotchDither {
    static let tileImage: CGImage? = makeTile(side: 96)

    private static func makeTile(side: Int) -> CGImage? {
        let bytesPerPixel = 4
        let bytesPerRow = side * bytesPerPixel
        var data = [UInt8](repeating: 0, count: side * bytesPerRow)
        var seed: UInt64 = 0x9E3779B97F4A7C15
        func next() -> UInt8 {
            seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
            return UInt8(truncatingIfNeeded: seed >> 24)
        }
        for i in stride(from: 0, to: data.count, by: bytesPerPixel) {
            let v = next()
            data[i] = v; data[i + 1] = v; data[i + 2] = v; data[i + 3] = 255
        }
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: &data, width: side, height: side, bitsPerComponent: 8,
                                  bytesPerRow: bytesPerRow, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        return ctx.makeImage()
    }
}

// MARK: - Control button

/// A quiet hairline-glass control (record / settings). A soft chip fades in on hover; a small
/// scale + dim on press. Drawn entirely in `draw(_:)` so there is no layer/cell ordering to
/// fight, and it works as first-mouse inside the non-activating panel.
final class NotchControlButton: NSControl {
    private let onAction: () -> Void
    private var baseImage: NSImage?
    private var hovering = false { didSet { if hovering != oldValue { needsDisplay = true } } }
    private var pressed = false { didSet { if pressed != oldValue { needsDisplay = true } } }
    private var trackingAreaRef: NSTrackingArea?

    init(systemName: String, tint: NSColor, label: String, action: @escaping () -> Void) {
        self.onAction = action
        self.baseImage = notchTintedSymbol(systemName, pointSize: 11.5, weight: .semibold, color: tint)
        super.init(frame: NSRect(x: 0, y: 0, width: 28, height: 24))
        toolTip = label
        setAccessibilityLabel(label)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Swap the glyph/tint in place (the header's record button flips record ↔ stop).
    func update(systemName: String, tint: NSColor, label: String) {
        baseImage = notchTintedSymbol(systemName, pointSize: 11.5, weight: .semibold, color: tint)
        toolTip = label
        setAccessibilityLabel(label)
        needsDisplay = true
    }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 28, height: 24) }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let b = bounds

        // Hover chip.
        if hovering {
            let r = NSBezierPath(roundedRect: b, xRadius: 7, yRadius: 7)
            NSColor(white: 1, alpha: 0.10).setFill(); r.fill()
            r.lineWidth = 0.75
            NSColor(white: 1, alpha: 0.12).setStroke(); r.stroke()
        }

        // Symbol, centered, slightly scaled + dimmed on press.
        guard let img = baseImage else { return }
        let scale: CGFloat = pressed ? 0.94 : 1
        let alpha: CGFloat = (pressed ? 0.72 : (hovering ? 1.0 : 0.82))
        let s = NSSize(width: img.size.width * scale, height: img.size.height * scale)
        let rect = NSRect(x: (b.width - s.width) / 2, y: (b.height - s.height) / 2,
                          width: s.width, height: s.height)
        img.draw(in: rect, from: .zero, operation: .sourceOver, fraction: alpha)
    }

    // Hover.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingAreaRef { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        trackingAreaRef = t
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false; pressed = false }

    // Press + click.
    override func mouseDown(with event: NSEvent) { pressed = true }
    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        pressed = bounds.contains(p)
    }
    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let inside = bounds.contains(p)
        pressed = false
        if inside { onAction() }
    }
}
