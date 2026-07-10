import AppKit
import CoreText

// The hero moment of the product is the answer arriving — so it deserves better than an
// NSTextField repainting whole. This view renders the answer with CoreText and gives every
// glyph a *birth*: new characters fade in and settle upward over ~180 ms, staggered a few
// milliseconds apart, so streamed tokens pour onto the slab like ink meeting glass instead
// of teleporting. Layout and measurement share one CTFramesetter path, so the panel height
// always matches what is drawn.
//
// Selection is intentionally traded for the animation (this is glance-read UI); a right-click
// menu offers「拷贝回答」so the text is never locked away. Reduce Motion births instantly.
final class StreamingAnswerView: NSView {
    private var text = ""
    private var births: [CFTimeInterval] = []   // one per Character, aligned with `text`
    private var link: CADisplayLink?
    private var proxy: StreamProxy?
    private var frameCache: (text: String, width: CGFloat, pts: CGFloat, frame: CTFrame)?

    /// 「上一轮答案还挂着、新一轮思考中」的变暗态（镜像旧 answerLabel.alphaValue 逻辑）。
    var dimmed = false {
        didSet { if dimmed != oldValue { alphaValue = dimmed ? 0.45 : 1 } }
    }

    private static let birthDuration: CFTimeInterval = 0.18
    private static let stagger: CFTimeInterval = 0.012
    private static let staggerCap: CFTimeInterval = 0.22   // 长段整体到达时不无限排队
    private static let rise: CGFloat = 3
    /// CT 布局路径的高度（真实高度由量高决定；这里只需「足够高」且两处一致）。
    private static let layoutHeight: CGFloat = 100_000

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    override var isFlipped: Bool { true }

    // MARK: - Text (diff → births)

    /// Streaming contract: text grows by suffix during a turn and is replaced wholesale on a
    /// new turn. Common prefix keeps its births; everything after is born now, staggered.
    func setText(_ new: String) {
        guard new != text else { return }
        let now = CACurrentMediaTime()
        let newChars = Array(new)
        let oldChars = Array(text)
        var common = 0
        let limit = min(newChars.count, oldChars.count)
        while common < limit && newChars[common] == oldChars[common] { common += 1 }

        var next = Array(births.prefix(common))
        if reduceMotion {
            next.append(contentsOf: Array(repeating: now - 10, count: newChars.count - common))
        } else {
            for i in common..<newChars.count {
                let delay = min(Self.staggerCap, Double(i - common) * Self.stagger)
                next.append(now + delay)
            }
        }
        text = new
        births = next
        frameCache = nil
        needsDisplay = true
        updateLink()
    }

    /// 设置里改了回答字号 → 缓存按字号自动失效（`frameCache.pts` 参与命中判断），
    /// 这里只需触发重绘。
    func invalidateTypography() {
        needsDisplay = true
    }

    // MARK: - Shared typography (measure + render from the SAME framesetter)

    private static func font() -> NSFont { .systemFont(ofSize: Settings.answerTextSize.points) }

    /// CT-native attributed string. Font/paragraph go in under the CT keys — CoreText does not
    /// reliably honour TextKit's NSParagraphStyle, and a missed key silently falls back to
    /// Helvetica 12 (the classic CT pitfall).
    private static func ctAttributed(_ s: String, font: NSFont) -> NSAttributedString {
        var lineSpacing: CGFloat = 3
        let style = withUnsafeMutablePointer(to: &lineSpacing) { ptr -> CTParagraphStyle in
            var setting = CTParagraphStyleSetting(spec: .lineSpacingAdjustment,
                                                  valueSize: MemoryLayout<CGFloat>.size,
                                                  value: ptr)
            return CTParagraphStyleCreate(&setting, 1)
        }
        return NSAttributedString(string: s, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTParagraphStyleAttributeName as String): style,
        ])
    }

    static func measure(_ s: String, width: CGFloat) -> CGFloat {
        guard !s.isEmpty, width > 1 else { return 0 }
        let setter = CTFramesetterCreateWithAttributedString(ctAttributed(s, font: font()))
        let size = CTFramesetterSuggestFrameSizeWithConstraints(
            setter, CFRange(location: 0, length: 0), nil,
            CGSize(width: width, height: .greatestFiniteMagnitude), nil)
        return ceil(size.height)
    }

    private func currentFrame() -> CTFrame? {
        guard !text.isEmpty, bounds.width > 1 else { return nil }
        let pts = Settings.answerTextSize.points
        if let c = frameCache, c.text == text, c.width == bounds.width, c.pts == pts { return c.frame }
        let setter = CTFramesetterCreateWithAttributedString(Self.ctAttributed(text, font: Self.font()))
        let path = CGPath(rect: CGRect(x: 0, y: 0, width: bounds.width, height: Self.layoutHeight),
                          transform: nil)
        let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), path, nil)
        frameCache = (text, bounds.width, pts, frame)
        return frame
    }

    // MARK: - Draw (per-glyph alpha + rise; single font/colour for the whole answer)

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, let frame = currentFrame() else { return }
        let now = CACurrentMediaTime()
        let ctFont = Self.font() as CTFont
        let baseColor = NotchPalette.primary
        let utf16Births = Self.utf16BirthTable(text: text, births: births)

        // CT lays out y-up; the view is flipped (y-down). Flip once for the whole frame, then
        // shift the tall layout path so the first line sits at the view's top.
        ctx.saveGState()
        ctx.translateBy(x: 0, y: bounds.height)
        ctx.scaleBy(x: 1, y: -1)
        let shift = Self.layoutHeight - bounds.height

        let lines = CTFrameGetLines(frame) as! [CTLine]
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)

        for (li, line) in lines.enumerated() {
            let originX = origins[li].x
            let originY = origins[li].y - shift
            for run in CTLineGetGlyphRuns(line) as! [CTRun] {
                let count = CTRunGetGlyphCount(run)
                guard count > 0 else { continue }
                var glyphs = [CGGlyph](repeating: 0, count: count)
                var positions = [CGPoint](repeating: .zero, count: count)
                var indices = [CFIndex](repeating: 0, count: count)
                CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
                CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
                CTRunGetStringIndices(run, CFRange(location: 0, length: 0), &indices)
                // Fallback fonts (CT may substitute for kana/emoji): use the run's actual font.
                let runAttrs = CTRunGetAttributes(run) as NSDictionary
                let runFont = (runAttrs[kCTFontAttributeName] as! CTFont?) ?? ctFont

                for g in 0..<count {
                    let birth = indices[g] < utf16Births.count ? utf16Births[indices[g]] : -10
                    let a = reduceMotion ? 1 : easeOut(min(1, max(0, (now - birth) / Self.birthDuration)))
                    guard a > 0.001 else { continue }
                    ctx.setFillColor(baseColor.withAlphaComponent(baseColor.alphaComponent * a).cgColor)
                    // Rise-in: glyph starts 3 pt low (CT space is y-up → subtract).
                    var pos = CGPoint(x: originX + positions[g].x,
                                      y: originY + positions[g].y - (1 - a) * Self.rise)
                    var glyph = glyphs[g]
                    CTFontDrawGlyphs(runFont, &glyph, &pos, 1, ctx)
                }
            }
        }
        ctx.restoreGState()
    }

    private func easeOut(_ t: CFTimeInterval) -> CGFloat { CGFloat(1 - pow(1 - t, 2.4)) }

    private static func utf16BirthTable(text: String, births: [CFTimeInterval]) -> [CFTimeInterval] {
        var table: [CFTimeInterval] = []
        table.reserveCapacity(text.utf16.count)
        for (i, ch) in text.enumerated() {
            let b = i < births.count ? births[i] : -10
            for _ in 0..<String(ch).utf16.count { table.append(b) }
        }
        return table
    }

    // MARK: - Animation clock (runs only while glyphs are being born)

    private func updateLink() {
        guard !reduceMotion else { return }
        let now = CACurrentMediaTime()
        let animating = births.contains { now - $0 < Self.birthDuration + Self.staggerCap }
        guard animating else { return }
        if link == nil {
            let p = StreamProxy(self)
            proxy = p
            link = displayLink(target: p, selector: #selector(StreamProxy.tick))
            link?.add(to: .main, forMode: .common)
        }
        link?.isPaused = false
    }

    fileprivate func step() {
        needsDisplay = true
        let now = CACurrentMediaTime()
        let animating = births.contains { now - $0 < Self.birthDuration + 0.05 }
        if !animating { link?.isPaused = true }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { link?.isPaused = true } else { updateLink() }
    }

    deinit { link?.invalidate() }

    // MARK: - Copy affordance (selection was traded for the birth animation)

    override func menu(for event: NSEvent) -> NSMenu? {
        guard !text.isEmpty else { return nil }
        let menu = NSMenu()
        let item = NSMenuItem(title: AppStrings.current.copyAnswer,
                              action: #selector(copyAnswer), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return menu
    }

    @objc private func copyAnswer() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

private final class StreamProxy {
    weak var owner: StreamingAnswerView?
    init(_ o: StreamingAnswerView) { owner = o }
    @objc func tick() { owner?.step() }
}
