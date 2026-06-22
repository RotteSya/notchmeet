import AppKit
import QuartzCore

// The settings design system — pure AppKit, drawn by hand to the same standard as the
// notch and onboarding: obsidian material, a single crisp edge of light, triangular-PDF
// dither to kill banding, and motion that moves as one body. Nothing here is a stock
// macOS control; every plane, hairline, and easing curve exists to kill a "generic" tell:
// flat fills, banded gradients, hard rectangles, snapping motion.

// MARK: - Tokens

enum SK {
    /// Brand, unified with the notch + onboarding so the product reads as one designed thing.
    static let bg          = NSColor(srgbRed: 0.024, green: 0.027, blue: 0.043, alpha: 1) // #06070b
    static let accent      = NSColor(srgbRed: 0.490, green: 0.635, blue: 1.000, alpha: 1) // #7DA2FF
    static let accentHi    = NSColor(srgbRed: 0.660, green: 0.760, blue: 1.000, alpha: 1) // top sheen
    static let accentLo    = NSColor(srgbRed: 0.345, green: 0.470, blue: 0.910, alpha: 1) // grounded edge
    static let destructive = NSColor(srgbRed: 1.000, green: 0.310, blue: 0.270, alpha: 1) // #FF4F45
    static let warning     = NSColor(srgbRed: 1.000, green: 0.624, blue: 0.118, alpha: 1)

    /// Cool near-white with a breath of brand blue — the colour of screen light on glass.
    static let sheen       = NSColor(srgbRed: 0.82, green: 0.87, blue: 1.00, alpha: 1)

    static let ink         = NSColor(srgbRed: 0.965, green: 0.969, blue: 0.984, alpha: 1)
    static let secondary   = NSColor(white: 1, alpha: 0.60)
    static let tertiary    = NSColor(white: 1, alpha: 0.34)
    static func ink(_ a: CGFloat) -> NSColor { NSColor(white: 1, alpha: a) }

    /// Motion (seconds). Shared so panel, sidebar pill, and controls feel like one instrument.
    static let morph:   CFTimeInterval = 0.40
    static let control: CFTimeInterval = 0.16

    static func font(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        NSFont.systemFont(ofSize: size, weight: weight)
    }
    static func mono(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: size, weight: weight)
    }

    /// Device-pixel hairline width for the host's backing scale (0.5pt on Retina).
    static func hairline(_ view: NSView) -> CGFloat {
        let scale = view.window?.backingScaleFactor ?? 2
        return 1.0 / scale
    }
}

// MARK: - Gradient + path helpers

/// A CGGradient from `(color, location)` stops in sRGB.
func skGradient(_ stops: [(NSColor, CGFloat)]) -> CGGradient {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let colors = stops.map { ($0.0.usingColorSpace(.sRGB) ?? $0.0).cgColor } as CFArray
    let locations = stops.map { $0.1 }
    return CGGradient(colorsSpace: space, colors: colors, locations: locations)!
}

@inline(__always) func skLerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }

extension CGRect {
    /// Snap to whole device pixels so fills/strokes land crisp on the host's backing scale.
    func integralAligned(_ view: NSView) -> CGRect {
        let s = view.window?.backingScaleFactor ?? 2
        func r(_ v: CGFloat) -> CGFloat { (v * s).rounded() / s }
        return CGRect(x: r(minX), y: r(minY), width: r(width), height: r(height))
    }
}

extension CGContext {
    /// Fill `path` with a vertical gradient (top → bottom of `rect`).
    func fillLinear(_ path: CGPath, _ rect: CGRect, _ stops: [(NSColor, CGFloat)],
                    blend: CGBlendMode = .normal, flipped: Bool = true) {
        saveGState()
        addPath(path); clip()
        setBlendMode(blend)
        let top = flipped ? rect.minY : rect.maxY
        let bot = flipped ? rect.maxY : rect.minY
        drawLinearGradient(skGradient(stops),
                           start: CGPoint(x: rect.midX, y: top),
                           end: CGPoint(x: rect.midX, y: bot),
                           options: [])
        restoreGState()
    }
}

/// A solid-tinted copy of an SF Symbol (template images don't tint when drawn into an
/// arbitrary CGContext, so bake the colour in once).
func skSymbol(_ name: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSImage? {
    let cfg = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
    guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(cfg) else { return nil }
    let s = base.size
    let img = NSImage(size: s)
    img.lockFocus()
    color.set()
    let r = NSRect(origin: .zero, size: s)
    base.draw(in: r)
    r.fill(using: .sourceAtop)
    img.unlockFocus()
    img.isTemplate = false
    return img
}

// MARK: - Critically-damped spring

/// A re-targetable spring integrator — the heart of the "buttery" motion. Unlike a fixed
/// duration tween it can be re-aimed mid-flight (click sidebar items fast and the pill
/// chases without snapping). Tuned to settle without overshoot for chrome, with a touch of
/// life for thumbs.
final class Spring {
    var value: CGFloat
    var target: CGFloat
    private var velocity: CGFloat = 0
    private let stiffness: CGFloat
    private let damping: CGFloat

    init(_ v: CGFloat, stiffness: CGFloat = 320, damping: CGFloat = 30) {
        value = v; target = v
        self.stiffness = stiffness; self.damping = damping
    }

    /// Jump with no motion (Reduce Motion / first layout).
    func snap(_ v: CGFloat) { value = v; target = v; velocity = 0 }

    /// Advance by `dt` seconds. Returns true while still moving.
    @discardableResult
    func step(_ dt: CGFloat) -> Bool {
        let h = min(max(dt, 1.0 / 240), 1.0 / 30)        // clamp to keep the integrator stable
        let force = -stiffness * (value - target) - damping * velocity
        velocity += force * h
        value += velocity * h
        if abs(velocity) < 0.06 && abs(value - target) < 0.06 {
            value = target; velocity = 0; return false
        }
        return true
    }

    var settled: Bool { velocity == 0 && value == target }
}

// MARK: - Display loop

/// A self-pausing display-link loop. Drives one or more springs and stops itself the frame
/// they all settle, so idle controls cost nothing. Uses a weak proxy to avoid a retain cycle.
final class DisplayLoop {
    private weak var host: NSView?
    private var link: CADisplayLink?
    private var proxy: Proxy?
    private var last: CFTimeInterval = 0

    /// Return true to keep ticking, false to pause.
    var onTick: ((CGFloat) -> Bool)?

    init(host: NSView) { self.host = host }

    func start() {
        guard let host, host.window != nil else { return }
        if link == nil {
            let p = Proxy(self); proxy = p
            link = host.displayLink(target: p, selector: #selector(Proxy.tick))
            link?.add(to: .main, forMode: .common)
        }
        last = CACurrentMediaTime()
        link?.isPaused = false
    }

    func stop() { link?.isPaused = true }

    fileprivate func tick() {
        let now = CACurrentMediaTime()
        let dt = CGFloat(now - last)
        last = now
        if onTick?(dt) != true { link?.isPaused = true }
    }

    deinit { link?.invalidate() }

    private final class Proxy {
        weak var owner: DisplayLoop?
        init(_ o: DisplayLoop) { owner = o }
        @objc func tick() { owner?.tick() }
    }
}

// MARK: - Reduce Motion

enum SKMotion {
    static var reduced: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
}

// MARK: - Dither

/// A static, cached fine-noise tile — triangular-PDF-ish white noise, the same anti-banding
/// device used across the product. Reuses the notch tile when present; otherwise builds its own.
enum SKDither {
    static let tile: CGImage? = NotchDither.tileImage ?? makeTile(96)

    private static func makeTile(_ side: Int) -> CGImage? {
        let bpp = 4, bpr = side * 4
        var data = [UInt8](repeating: 0, count: side * bpr)
        var seed: UInt64 = 0x9E3779B97F4A7C15
        func next() -> UInt8 {
            seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
            return UInt8(truncatingIfNeeded: seed >> 24)
        }
        for i in stride(from: 0, to: data.count, by: bpp) {
            let v = next(); data[i] = v; data[i+1] = v; data[i+2] = v; data[i+3] = 255
        }
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: &data, width: side, height: side, bitsPerComponent: 8,
                                  bytesPerRow: bpr, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        return ctx.makeImage()
    }

    /// Tile the dither over `rect` at a whisper of opacity, additively. Call inside a clip.
    static func paint(_ ctx: CGContext, in rect: CGRect, alpha: CGFloat = 0.022) {
        guard let tile else { return }
        ctx.saveGState()
        ctx.setBlendMode(.plusLighter)
        ctx.setAlpha(alpha)
        ctx.draw(tile, in: CGRect(x: rect.minX, y: rect.minY, width: 96, height: 96), byTiling: true)
        ctx.restoreGState()
    }
}

// MARK: - Hairline

/// A true device-pixel rule with an optional faint top-edge of light, so planes read as
/// stacked glass rather than printed lines.
final class SKHairline: NSView {
    enum Axis { case horizontal, vertical }
    var axis: Axis = .horizontal
    var color: NSColor = SK.ink(0.09)
    /// When true the rule carries a 1px brighter lip on its upper side (light from above).
    var lit: Bool = false

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let hair = SK.hairline(self)
        let b = bounds
        if axis == .horizontal {
            ctx.setFillColor(color.cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: b.width, height: hair))
            if lit {
                ctx.setBlendMode(.plusLighter)
                ctx.setFillColor(SK.ink(0.05).cgColor)
                ctx.fill(CGRect(x: 0, y: hair, width: b.width, height: hair))
            }
        } else {
            ctx.setFillColor(color.cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: hair, height: b.height))
        }
    }
}

// MARK: - Text helpers

enum SKText {
    static func label(_ string: String, font: NSFont, color: NSColor,
                      tracking: CGFloat = 0, align: NSTextAlignment = .left,
                      lineSpacing: CGFloat = 0) -> NSTextField {
        let f = NSTextField(labelWithString: string)
        f.font = font
        f.textColor = color
        f.alignment = align
        f.maximumNumberOfLines = 0
        f.lineBreakMode = .byWordWrapping
        f.allowsDefaultTighteningForTruncation = false
        if tracking != 0 || lineSpacing != 0 {
            f.attributedStringValue = attributed(string, font: font, color: color,
                                                 tracking: tracking, align: align, lineSpacing: lineSpacing)
        }
        f.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return f
    }

    static func attributed(_ string: String, font: NSFont, color: NSColor,
                           tracking: CGFloat = 0, align: NSTextAlignment = .left,
                           lineSpacing: CGFloat = 0) -> NSAttributedString {
        let p = NSMutableParagraphStyle()
        p.alignment = align
        p.lineSpacing = lineSpacing
        p.lineBreakMode = .byWordWrapping
        var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: p]
        if tracking != 0 { attrs[.kern] = tracking }
        return NSAttributedString(string: string, attributes: attrs)
    }
}
