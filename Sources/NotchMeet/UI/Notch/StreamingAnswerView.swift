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

    /// 答案超过可视高度时的滚动位移（0 = 顶部）。
    ///
    /// 刻意**不**自动跟随底部：这是提词器，人是从第一行开始念的，自动滚到底等于
    /// 把还没念的内容推出视野。新答案到达时归零，之后完全由用户滚轮控制。
    private(set) var scrollOffset: CGFloat = 0

    /// 内容总高（按当前宽度排版）。宽度为 0 时不排版。
    private var contentHeight: CGFloat {
        guard bounds.width > 1, !text.isEmpty else { return 0 }
        return Self.measure(text, width: bounds.width)
    }

    /// 还能往下滚多少；0 = 内容全部可见（此时不画渐隐提示、也不吃滚轮）。
    var maxScroll: CGFloat { max(0, contentHeight - bounds.height) }
    var isScrollable: Bool { maxScroll > 0.5 }

    func scroll(by delta: CGFloat) {
        let next = min(max(0, scrollOffset - delta), maxScroll)
        guard abs(next - scrollOffset) > 0.01 else { return }
        scrollOffset = next
        needsDisplay = true
    }

    private static let birthDuration: CFTimeInterval = 0.18
    private static let stagger: CFTimeInterval = 0.012
    private static let staggerCap: CFTimeInterval = 0.22   // 长段整体到达时不无限排队
    private static let rise: CGFloat = 3
    /// CT 布局路径的高度（真实高度由量高决定；这里只需「足够高」且两处一致）。
    private static let layoutHeight: CGFloat = 100_000
    /// 行剔除的上下余量（一行日文 15pt 约 25pt 高，留一行余量避免边界行被误剔）。
    private static let lineCull: CGFloat = 40

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // 视口裁剪。CT 的 frame 高度是 layoutHeight（「足够高」），draw 会把**全部**行都
        // 送进上下文；答案区一旦封顶（NotchMetrics.maxAnswerHeight），超出的行若不裁掉
        // 就会画到视图之外、越过卡片下缘继续渲染。
        //
        // 这条是实机截图发现的：布局数学全对（card 520x538 / y=94 / answerH=420），
        // 单测也全绿——错在绘制没有边界。用 clipsToBounds 而不是在 draw 里 ctx.clip：
        // 前者对图层树同样生效，后者只管当前这次 drawRect。
        clipsToBounds = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

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
        // 纯追加（流式 delta）保持当前位移；整段换新（新一轮答案、回看切换）则回到顶部——
        // 否则用户会盯着一段空白，以为答案没出来。
        if common < oldChars.count { scrollOffset = 0 }
        text = new
        births = next
        frameCache = nil
        rebuildBirthTable()
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

    /// 测量结果缓存。流式期每个 delta 都会经由 `NotchType.answerHeight` 走到这里，
    /// 而每次都新建一个 framesetter 对**整串**答案重新排版 —— 累计是 O(n²)，
    /// 并且全部发生在主线程上，与出生动画、面板动画抢同一条 runloop。
    /// 键包含字号：设置里改字号后缓存自动失效。
    private static var measureCache: [MeasureKey: CGFloat] = [:]
    private struct MeasureKey: Hashable {
        let text: String
        let width: CGFloat
        let pts: CGFloat
    }

    static func measure(_ s: String, width: CGFloat) -> CGFloat {
        guard !s.isEmpty, width > 1 else { return 0 }
        let key = MeasureKey(text: s, width: width, pts: Settings.answerTextSize.points)
        if let hit = measureCache[key] { return hit }
        let setter = CTFramesetterCreateWithAttributedString(ctAttributed(s, font: font()))
        let size = CTFramesetterSuggestFrameSizeWithConstraints(
            setter, CFRange(location: 0, length: 0), nil,
            CGSize(width: width, height: .greatestFiniteMagnitude), nil)
        let height = ceil(size.height)
        // 流式期同一段文本会不断增长，缓存条目也随之增加；超过阈值整体丢弃，
        // 下一轮重新填充（比 LRU 简单，且这里的重算成本本来就只有一次）。
        if measureCache.count > 240 { measureCache.removeAll(keepingCapacity: true) }
        measureCache[key] = height
        return height
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
        let utf16Births = birthTableCache

        // CT lays out y-up; the view is flipped (y-down). Flip once for the whole frame, then
        // shift the tall layout path so the first line sits at the view's top.
        ctx.saveGState()
        ctx.translateBy(x: 0, y: bounds.height)
        ctx.scaleBy(x: 1, y: -1)
        let shift = Self.layoutHeight - bounds.height + scrollOffset

        let lines = CTFrameGetLines(frame) as! [CTLine]
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)

        for (li, line) in lines.enumerated() {
            let originX = origins[li].x
            let originY = origins[li].y - shift
            // 视口外的行直接跳过：封顶后长答案每帧仍遍历全部行是纯浪费，
            // 而流式期这条 draw 与出生动画、面板动画抢同一条 runloop。
            if originY < -Self.lineCull || originY > bounds.height + Self.lineCull { continue }
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
        drawOverflowHint(ctx)
    }

    /// 「下面还有」的可见凭据。旧行为是超出屏幕后被窗口静默切掉——用户读到底部
    /// 断在半句上，且完全不知道后面还有内容。上下各一道渐隐，有内容的方向才画。
    private func drawOverflowHint(_ ctx: CGContext) {
        guard isScrollable else { return }
        let fade: CGFloat = 22
        let bg = NotchPalette.background
        func band(_ rect: CGRect, topDown: Bool) {
            ctx.saveGState()
            ctx.clip(to: rect)
            ctx.drawLinearGradient(
                skGradient([(bg.withAlphaComponent(topDown ? 0.95 : 0), 0),
                            (bg.withAlphaComponent(topDown ? 0 : 0.95), 1)]),
                start: CGPoint(x: rect.midX, y: rect.minY),
                end: CGPoint(x: rect.midX, y: rect.maxY), options: [])
            ctx.restoreGState()
        }
        if scrollOffset > 0.5 {
            band(CGRect(x: 0, y: 0, width: bounds.width, height: fade), topDown: true)
        }
        if scrollOffset < maxScroll - 0.5 {
            band(CGRect(x: 0, y: bounds.height - fade, width: bounds.width, height: fade),
                 topDown: false)
        }
    }

    /// 滚轮。面板是 `.nonactivatingPanel` 且 `canBecomeKey = false`，拿不到键盘事件，
    /// 所以滚轮是长答案唯一的翻阅手段（不再多占全局热键，见 AppController 的注释）。
    override func scrollWheel(with event: NSEvent) {
        guard isScrollable else { super.scrollWheel(with: event); return }
        // 触控板给的是精确增量，鼠标滚轮给的是「行」——后者乘一个行高量级才跟手。
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY
                                                    : event.scrollingDeltaY * 16
        scroll(by: delta)
    }

    private func easeOut(_ t: CFTimeInterval) -> CGFloat { CGFloat(1 - pow(1 - t, 2.4)) }

    /// UTF-16 偏移 → 出生时刻。旧实现在**每一帧** draw 里全量重建，且每个字符
    /// 都要 `String(ch)` 分配一次；日文长答案在 ProMotion 上是每秒数万次无谓分配。
    /// 现在随 `setText` 增量维护（text/births 只在那里变）。
    private var birthTableCache: [CFTimeInterval] = []

    private func rebuildBirthTable() {
        var table: [CFTimeInterval] = []
        table.reserveCapacity(text.utf16.count)
        for (i, ch) in text.enumerated() {
            let b = i < births.count ? births[i] : -10
            // utf16 长度不需要建临时 String：直接问 unicodeScalars 的编码宽度。
            let width = ch.unicodeScalars.reduce(0) { $0 + UTF16.width($1) }
            for _ in 0..<width { table.append(b) }
        }
        birthTableCache = table
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
            let l = displayLink(target: p, selector: #selector(StreamProxy.tick))
            // 出生动画只有 180ms 的窗口，60fps 足够；不设上限时 ProMotion 会跑到
            // 120Hz，长答案下每秒上万次逐字形 draw，流式中后段掉帧且明显耗电。
            l.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
            l.add(to: .main, forMode: .common)
            link = l
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
        ScreenShareGuard.protect(menu)   // 面试中右键 ＝ 菜单不能进共享帧
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
