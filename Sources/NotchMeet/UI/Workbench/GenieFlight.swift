import AppKit
import Metal
import MetalKit
import QuartzCore

/// 「准备面试」的飞入仪式：工作台窗口的快照贴在一张 40×48 顶点网格上，由 Metal
/// vertex shader 沿贝塞尔漏斗把整个平面「吸」进刘海开孔——macOS 用户对 Genie 有
/// 三十年肌肉记忆，「最小化到 Dock」的隐喻在此平移为「收纳进刘海」。
///
/// 工程边界：
///  - 单 draw call、约 4K 顶点、每帧 GPU <0.5ms——Intel 核显同样 60fps 富余；
///  - shader 走仓库既有的运行时编译惯例（`makeLibrary(source:)`），零 build 依赖；
///  - 飞行 Panel 压在刘海 Panel **之下**：内容滑进石板区域即被吞没（吸收错觉的全部）；
///  - 快照与网格在动画首帧**之前**备好；飞行期零布局、零 SwiftUI；
///  - Reduce Motion / 无 Metal / 快照失败 → 返回 false，调用方走直切降级；
///  - `FI_SLOW_FLYIN=1`（DEBUG）→ 2.4s 慢速逐帧检查（同 FI_SLOW_MORPH 惯例）。
enum GenieFlight {
    /// 网格密度：列 × 行。漏斗形变是低频曲面，40×48 已到视觉上限。
    private static let cols = 40
    private static let rows = 48

    static var duration: CFTimeInterval {
        #if DEBUG
        if ProcessInfo.processInfo.environment["FI_SLOW_FLYIN"] == "1" { return 2.4 }
        #endif
        return 0.62
    }

    /// 启动飞行。返回 false = 环境不支持（调用方必须自己降级，不得静默丢仪式）。
    /// `onMouthReached` 在内容开始涌入开孔时触发（≈72% 进度，刘海光场开始吸气）。
    @discardableResult
    static func fly(from window: NSWindow,
                    sheet: SheetModel,
                    to mouth: NSRect,
                    belowWindowNumber: Int,
                    onMouthReached: @escaping () -> Void,
                    completion: @escaping () -> Void) -> Bool {
        guard !SKMotion.reduced,
              let device = MTLCreateSystemDefaultDevice() else {
            NSLog("[flight] unavailable (reduced-motion/metal) — direct fallback")
            return false
        }
        // 薄片在动画开始前直绘完成（一次性成本 ~几 ms，绝不落在飞行首帧里）。
        guard let cg = Self.drawSheet(sheet, size: window.frame.size,
                                      scale: window.backingScaleFactor) else {
            NSLog("[flight] sheet draw failed — direct fallback")
            return false
        }

        // 舞台 = 起点窗口 ∪ 落点开孔（可跨屏：NSScreen 全局坐标系是统一的）。
        let stage = window.frame.union(mouth)
        guard let view = FlightView(device: device, snapshot: cg,
                                    start: window.frame, mouth: mouth, stage: stage,
                                    duration: duration,
                                    onMouthReached: onMouthReached,
                                    completion: completion) else { return false }

        let panel = NSPanel(contentRect: stage,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        // 飞行帧里是完整的工作台内容（公司名 + 个人经历）——与工作台同门保护。
        ScreenShareGuard.exclude(panel)
        panel.contentView = view
        view.onDone = { [weak panel] in panel?.orderOut(nil) }
        panel.orderFrontRegardless()
        // 压到刘海之下：到达的内容被石板吞没，而不是盖在石板上。
        panel.order(.below, relativeTo: belowWindowNumber)
        view.start()
        #if DEBUG
        if SettingsWindowController.visualQA {
            try? "\(panel.windowNumber)".write(toFile: "/tmp/nm-flight-window.txt",
                                               atomically: true, encoding: .utf8)
        }
        #endif
        return true
    }

    // MARK: - 飞行薄片（同设计系统直绘）

    /// 飞行薄片的内容模型：与工作台同一批 live store 的数据快照。
    struct SheetModel {
        struct RailRow { let title: String; let subtitle: String?; let armed: Bool }
        struct Card { let title: String; let detail: String; let locked: Bool }
        let windowTitle: String
        let railRows: [RailRow]
        let centerTitle: String
        let cards: [Card]
        let readinessTitle: String
        let readinessRows: [(String, String)]
        let progressLabel: String
        let progress: CGFloat
    }

    /// 为什么是「直绘」而不是活窗口的像素拷贝——五条路全部实测于这套
    /// IOSurface 背衬的 layer-backed 树，悉数阵亡：
    ///  - `cacheDisplay` / `layer.render(in:)` / `displayIgnoringOpacity`：全透明
    ///    （CA 接管后 display 族方法不再落到 CG）；
    ///  - `dataWithPDF`（打印路径）：能画文本但滚动内容错位、plusLighter 混合失真；
    ///  - `CARenderer`：拒绝渲染已挂接窗口的层树（输出品红）；
    ///  - `CGWindowList`/SCK：被 sharingType=.none 挡死，临时翻开会把弹药面板泄进
    ///    共享帧——红线，绝不做。
    /// 于是用同一套 SK tokens + 同一批 live 数据把工作台画像直绘成纹理：0.6s 的
    /// 形变中没有人阅读像素级文本，视觉血统一致即忠实。
    private static func drawSheet(_ m: SheetModel, size: CGSize, scale: CGFloat) -> CGImage? {
        let w = Int(size.width * scale), h = Int(size.height * scale)
        guard w > 1, h > 1 else { return nil }
        let cs = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: cs, bitmapInfo: info) else { return nil }
        // 翻转成 top-down 作图（与工作台的 flipped 视图同向），出图即正立。
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: scale, y: -scale)
        let g = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = g
        defer { NSGraphicsContext.restoreGraphicsState() }

        let W = size.width, H = size.height
        let railW: CGFloat = 220, readyW: CGFloat = 300

        // 地：产品黑曜石 + 三栏的面。
        ctx.setFillColor(SK.bg.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        ctx.setFillColor(SK.ink(0.05).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: railW, height: H))
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.62).cgColor)
        ctx.fill(CGRect(x: railW, y: 0, width: W - railW, height: H))
        ctx.setFillColor(SK.ink(0.085).cgColor)
        ctx.fill(CGRect(x: railW, y: 0, width: 1, height: H))
        ctx.fill(CGRect(x: W - readyW, y: 0, width: 1, height: H))

        func text(_ s: String, _ font: NSFont, _ color: NSColor, at p: CGPoint, maxWidth: CGFloat) {
            let a = SKText.attributed(s, font: font, color: color, lineBreak: .byTruncatingTail)
            a.draw(with: CGRect(x: p.x, y: p.y, width: maxWidth, height: font.pointSize + 8),
                   options: [.usesLineFragmentOrigin])
        }

        // 左栏：身份 + 目标行（武装点 + 选中胶囊）。
        text("NotchMeet", SK.font(15, .semibold), SK.ink, at: CGPoint(x: 22, y: 40), maxWidth: railW - 40)
        text(m.windowTitle, SK.font(11.5), SK.secondary, at: CGPoint(x: 22, y: 58), maxWidth: railW - 40)
        var y: CGFloat = 114
        for row in m.railRows.prefix(6) {
            if row.armed {
                let pill = CGPath(roundedRect: CGRect(x: 12, y: y - 8, width: railW - 24, height: 42),
                                  cornerWidth: 9, cornerHeight: 9, transform: nil)
                ctx.addPath(pill)
                ctx.setFillColor(SK.ink(0.14).cgColor)
                ctx.fillPath()
                ctx.setFillColor(SK.accent.cgColor)
                ctx.fillEllipse(in: CGRect(x: railW - 26, y: y + 6, width: 6, height: 6))
            }
            text(row.title, SK.font(13, row.armed ? .medium : .regular),
                 row.armed ? SK.ink : SK.secondary, at: CGPoint(x: 40, y: y), maxWidth: railW - 70)
            if let sub = row.subtitle {
                text(sub, SK.font(10.5), SK.tertiary, at: CGPoint(x: 40, y: y + 17), maxWidth: railW - 70)
            }
            y += 46
        }

        // 中栏：标题 + 弹药卡（实线=已确认，虚线=草稿）。
        let cx = railW + 36
        let cw = W - railW - readyW - 72
        text(m.centerTitle, SK.font(23.5, .semibold), SK.ink, at: CGPoint(x: cx, y: 36), maxWidth: cw)
        var cy: CGFloat = 96
        for card in m.cards.prefix(4) {
            let rect = CGRect(x: cx, y: cy, width: cw, height: 74)
            let path = CGPath(roundedRect: rect, cornerWidth: 10, cornerHeight: 10, transform: nil)
            ctx.addPath(path)
            ctx.setFillColor(SK.ink(card.locked ? 0.055 : 0.03).cgColor)
            ctx.fillPath()
            ctx.addPath(path)
            ctx.setStrokeColor((card.locked ? SK.ink(0.16) : SK.ink(0.14)).cgColor)
            ctx.setLineWidth(1)
            if !card.locked { ctx.setLineDash(phase: 0, lengths: [4, 3]) }
            ctx.strokePath()
            ctx.setLineDash(phase: 0, lengths: [])
            text(card.title, SK.font(13, .semibold), SK.ink,
                 at: CGPoint(x: cx + 14, y: cy + 12), maxWidth: cw - 28)
            text(card.detail, SK.font(11.5), SK.secondary,
                 at: CGPoint(x: cx + 14, y: cy + 34), maxWidth: cw - 28)
            cy += 84
        }

        // 右栏：战备度 + 进度条 + 自检行。
        let rx = W - readyW + 36
        let rw = readyW - 72
        text(m.readinessTitle, SK.font(17, .semibold), SK.ink, at: CGPoint(x: rx, y: 36), maxWidth: rw)
        text(m.progressLabel, SK.font(12, .medium), SK.ink, at: CGPoint(x: rx, y: 76), maxWidth: rw)
        let track = CGPath(roundedRect: CGRect(x: rx, y: 100, width: rw, height: 5),
                           cornerWidth: 2.5, cornerHeight: 2.5, transform: nil)
        ctx.addPath(track)
        ctx.setFillColor(SK.ink(0.08).cgColor)
        ctx.fillPath()
        if m.progress > 0 {
            let fill = CGPath(roundedRect: CGRect(x: rx, y: 100,
                                                  width: max(5, rw * min(1, m.progress)), height: 5),
                              cornerWidth: 2.5, cornerHeight: 2.5, transform: nil)
            ctx.addPath(fill)
            ctx.setFillColor(SK.accent.cgColor)
            ctx.fillPath()
        }
        var ry: CGFloat = 126
        for (label, value) in m.readinessRows.prefix(7) {
            text(label, SK.font(11.5), SK.secondary, at: CGPoint(x: rx, y: ry), maxWidth: rw * 0.5)
            let a = SKText.attributed(value, font: SK.font(11.5, .medium), color: SK.ink,
                                      align: .right, lineBreak: .byTruncatingTail)
            a.draw(with: CGRect(x: rx + rw * 0.35, y: ry, width: rw * 0.65, height: 18),
                   options: [.usesLineFragmentOrigin])
            ry += 24
        }
        // 终点按钮：仪式的起点如实入画。
        let btn = CGPath(roundedRect: CGRect(x: rx, y: ry + 16, width: rw, height: 40),
                         cornerWidth: 10, cornerHeight: 10, transform: nil)
        ctx.addPath(btn)
        ctx.setFillColor(SK.accent.cgColor)
        ctx.fillPath()

        return ctx.makeImage()
    }

    // MARK: - Flight view（CAMetalLayer + 自驱 display link，同 NotchLuma 惯例）

    final class FlightView: NSView {
        private let metalLayer = CAMetalLayer()
        private var pipeline: MTLRenderPipelineState?
        private var queue: MTLCommandQueue?
        private var texture: MTLTexture?
        private var vertexBuffer: MTLBuffer?
        private var indexBuffer: MTLBuffer?
        private var indexCount = 0

        private let startRect: NSRect     // panel-local, y-up
        private let mouthRect: NSRect
        private let duration: CFTimeInterval
        private let onMouthReached: () -> Void
        private let completion: () -> Void
        var onDone: (() -> Void)?

        private var link: CADisplayLink?
        private var proxy: FlightProxy?
        private var t0: CFTimeInterval = 0
        private var mouthFired = false
        private var finished = false

        struct Uniforms {
            var startRect: SIMD4<Float>
            var endRect: SIMD4<Float>
            var viewport: SIMD2<Float>
            var t: Float
            var lag: Float
        }

        init?(device: MTLDevice, snapshot: CGImage,
              start: NSRect, mouth: NSRect, stage: NSRect,
              duration: CFTimeInterval,
              onMouthReached: @escaping () -> Void,
              completion: @escaping () -> Void) {
            self.startRect = NSRect(x: start.minX - stage.minX, y: start.minY - stage.minY,
                                    width: start.width, height: start.height)
            self.mouthRect = NSRect(x: mouth.minX - stage.minX, y: mouth.minY - stage.minY,
                                    width: mouth.width, height: mouth.height)
            self.duration = duration
            self.onMouthReached = onMouthReached
            self.completion = completion
            super.init(frame: NSRect(origin: .zero, size: stage.size))

            guard let lib = try? device.makeLibrary(source: Self.shader, options: nil),
                  let vfn = lib.makeFunction(name: "genie_vertex"),
                  let ffn = lib.makeFunction(name: "genie_fragment") else { return nil }
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = vfn
            desc.fragmentFunction = ffn
            desc.colorAttachments[0].pixelFormat = .bgra8Unorm
            desc.colorAttachments[0].isBlendingEnabled = true
            desc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
            desc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            desc.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
            desc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            guard let p = try? device.makeRenderPipelineState(descriptor: desc),
                  let q = device.makeCommandQueue() else { return nil }
            pipeline = p
            queue = q

            let loader = MTKTextureLoader(device: device)
            guard let tex = try? loader.newTexture(cgImage: snapshot, options: [
                .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
                .textureStorageMode: NSNumber(value: MTLStorageMode.private.rawValue),
                .SRGB: NSNumber(value: false),
            ]) else { return nil }
            texture = tex

            buildMesh(device: device)

            // 同 NotchLuma 惯例：metalLayer 作为 backing layer 的 sublayer 挂载
            // （替换 backing layer 在 AppKit 下不可靠——那正是「面板一片空白」的坑）。
            wantsLayer = true
            metalLayer.device = device
            metalLayer.pixelFormat = .bgra8Unorm
            // 非 framebufferOnly：可回读——窗口截图（QA 连拍）与屏幕录制才能拍到内容。
            // 单纹理单 draw call，这点代价可以忽略。
            metalLayer.framebufferOnly = false
            metalLayer.isOpaque = false
            metalLayer.backgroundColor = .clear
            layer?.addSublayer(metalLayer)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        private func buildMesh(device: MTLDevice) {
            let cols = GenieFlight.cols
            let rows = GenieFlight.rows
            var uvs: [SIMD2<Float>] = []
            uvs.reserveCapacity((cols + 1) * (rows + 1))
            for r in 0...rows {
                for c in 0...cols {
                    uvs.append(SIMD2(Float(c) / Float(cols), Float(r) / Float(rows)))
                }
            }
            var indices: [UInt32] = []
            indices.reserveCapacity(cols * rows * 6)
            for r in 0..<rows {
                for c in 0..<cols {
                    let i0 = UInt32(r * (cols + 1) + c)
                    let i1 = i0 + 1
                    let i2 = i0 + UInt32(cols + 1)
                    let i3 = i2 + 1
                    indices += [i0, i2, i1, i1, i2, i3]
                }
            }
            indexCount = indices.count
            vertexBuffer = device.makeBuffer(bytes: uvs,
                                             length: MemoryLayout<SIMD2<Float>>.stride * uvs.count)
            indexBuffer = device.makeBuffer(bytes: indices,
                                            length: MemoryLayout<UInt32>.stride * indices.count)
        }

        func start() {
            let scale = window?.backingScaleFactor ?? 2
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            metalLayer.frame = bounds
            CATransaction.commit()
            metalLayer.contentsScale = scale
            metalLayer.drawableSize = CGSize(width: bounds.width * scale,
                                             height: bounds.height * scale)
            NSLog("[flight] genie started: %.0f×%.0f → mouth %.0f×%.0f",
                  startRect.width, startRect.height, mouthRect.width, mouthRect.height)
            t0 = CACurrentMediaTime()
            let p = FlightProxy(self)
            proxy = p
            link = displayLink(target: p, selector: #selector(FlightProxy.tick))
            link?.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
            link?.add(to: .main, forMode: .common)
            render(t: 0)   // 首帧立即在位——真窗此刻才隐藏，无空档
        }

        fileprivate func step() {
            let t = min(1, (CACurrentMediaTime() - t0) / duration)
            if !mouthFired, t >= 0.72 {
                mouthFired = true
                onMouthReached()
            }
            render(t: Float(t))
            if t >= 1, !finished {
                finished = true
                link?.invalidate()
                link = nil
                onDone?()
                completion()
            }
        }

        private func render(t: Float) {
            guard let pipeline, let queue, let texture,
                  let vertexBuffer, let indexBuffer,
                  let drawable = metalLayer.nextDrawable(),
                  let cmd = queue.makeCommandBuffer() else { return }
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = drawable.texture
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            pass.colorAttachments[0].storeAction = .store
            guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }
            var u = Uniforms(
                startRect: SIMD4(Float(startRect.minX), Float(startRect.minY),
                                 Float(startRect.width), Float(startRect.height)),
                endRect: SIMD4(Float(mouthRect.minX), Float(mouthRect.minY),
                               Float(mouthRect.width), Float(mouthRect.height)),
                viewport: SIMD2(Float(bounds.width), Float(bounds.height)),
                t: t,
                lag: 0.55)
            enc.setRenderPipelineState(pipeline)
            enc.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
            enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
            enc.setFragmentTexture(texture, index: 0)
            enc.drawIndexedPrimitives(type: .triangle, indexCount: indexCount,
                                      indexType: .uint32, indexBuffer: indexBuffer,
                                      indexBufferOffset: 0)
            enc.endEncoding()
            #if DEBUG
            // QA 帧回读：窗口级截屏拍不到 CAMetalLayer 的直通呈现，验收走 GPU 内 blit。
            // FI_FLIGHT_DUMP=/path/prefix → 在 25%/50%/80% 各落一张 PNG。
            if let prefix = ProcessInfo.processInfo.environment["FI_FLIGHT_DUMP"],
               let mark = dumpMarks.first, t >= mark {
                dumpMarks.removeFirst()
                dumpFrame(drawable.texture, cmd: cmd,
                          path: "\(prefix)-\(Int(mark * 100)).png")
            }
            #endif
            cmd.present(drawable)
            cmd.commit()
        }

        #if DEBUG
        private var dumpMarks: [Float] = [0.25, 0.5, 0.8]

        /// blit 到共享内存 → 完成后写 PNG（bgra8 → CGImage）。只在 QA 钩子下走。
        private func dumpFrame(_ texture: MTLTexture, cmd: MTLCommandBuffer, path: String) {
            guard let device = metalLayer.device else { return }
            let w = texture.width, h = texture.height
            let bytesPerRow = w * 4
            guard let buffer = device.makeBuffer(length: bytesPerRow * h,
                                                 options: .storageModeShared),
                  let blit = cmd.makeBlitCommandEncoder() else { return }
            blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0,
                      sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                      sourceSize: MTLSize(width: w, height: h, depth: 1),
                      to: buffer, destinationOffset: 0,
                      destinationBytesPerRow: bytesPerRow,
                      destinationBytesPerImage: bytesPerRow * h)
            blit.endEncoding()
            cmd.addCompletedHandler { _ in
                let cs = CGColorSpaceCreateDeviceRGB()
                let info = CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue
                guard let ctx = CGContext(data: buffer.contents(), width: w, height: h,
                                          bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                          space: cs, bitmapInfo: info),
                      let img = ctx.makeImage() else { return }
                let rep = NSBitmapImageRep(cgImage: img)
                if let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: path))
                    NSLog("[flight] dumped frame → %@", path)
                }
            }
        }
        #endif

        private final class FlightProxy {
            weak var owner: FlightView?
            init(_ o: FlightView) { owner = o }
            @objc func tick() { owner?.step() }
        }

        /// Genie 漏斗（panel-local 坐标，y 向上；开孔在上方）：
        ///  - 每行有自己的进度：顶行先动（lag 错峰），底行最后离场——「被吸走」的时序骨架；
        ///  - x 随「当前高度接近开孔的程度」向开孔宽度收拢（smoothstep^1.6 的漏斗曲线）；
        ///  - 结尾 14% 全局淡出，与石板吞没交接。
        static let shader = """
        #include <metal_stdlib>
        using namespace metal;

        struct U {
            float4 sr;        // startRect x,y,w,h (panel-local, y-up)
            float4 er;        // mouthRect
            float2 viewport;
            float  t;
            float  lag;
        };
        struct VOut {
            float4 pos [[position]];
            float2 uv;
            float  alpha;
        };

        vertex VOut genie_vertex(uint vid [[vertex_id]],
                                 const device float2 *uvs [[buffer(0)]],
                                 constant U &u [[buffer(1)]]) {
            float2 uv = uvs[vid];
            // 行进度：v=1（顶）先动，v=0（底）最后；out-cubic 让离场安静减速。
            float rp = clamp(u.t * (1.0 + u.lag) - (1.0 - uv.y) * u.lag, 0.0, 1.0);
            float e = 1.0 - pow(1.0 - rp, 3.0);

            float ySrc = u.sr.y + uv.y * u.sr.w;
            float yDst = u.er.y + uv.y * u.er.w;
            float y = mix(ySrc, yDst, e);

            // 漏斗：越接近开孔高度，x 越收进开孔宽度。
            float q = clamp((y - u.sr.y) / max(1.0, u.er.y - u.sr.y), 0.0, 1.0);
            float s = pow(smoothstep(0.0, 1.0, q), 1.6);
            float xBig = u.sr.x + uv.x * u.sr.z;
            float xSmall = u.er.x + uv.x * u.er.z;
            float x = mix(xBig, xSmall, s);

            VOut o;
            o.pos = float4(float2(x, y) / u.viewport * 2.0 - 1.0, 0.0, 1.0);
            o.uv = float2(uv.x, 1.0 - uv.y);
            o.alpha = 1.0 - smoothstep(0.86, 1.0, u.t);
            return o;
        }

        fragment float4 genie_fragment(VOut in [[stage_in]],
                                       texture2d<float> tex [[texture(0)]]) {
            constexpr sampler s(address::clamp_to_edge, filter::linear);
            float4 c = tex.sample(s, in.uv);
            return float4(c.rgb, c.a) * in.alpha;
        }
        """
    }
}
