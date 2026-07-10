import AppKit
import QuartzCore
import Metal

// The notch's interior LIGHT FIELD — a real GPU light simulation living inside the obsidian,
// not a painted gradient. Concept: the slab is machined black glass; the screen's light pools
// along its lower face and *responds to the interview*: it breathes while armed, swells with
// the interviewer's voice while listening, sweeps while the engine is thinking, and pulses
// with each arriving token while streaming. The top third stays pure black so the slab keeps
// fusing with the hardware cutout. Everything is deliberately dim — the field never competes
// with text; it makes the black feel *alive* instead of printed.
//
// 纯 Metal（运行时编译，无 build-system 依赖）；渲染循环只在有戏可演时运行（见 `needsMotion`），
// 折叠且待机时完全暂停 = 零功耗。Reduce Motion 时冻结在当前状态的定格帧。

// MARK: - Voice level bus

/// 音频线程 → 渲染线程的声级直通道。刻意绕开 `AnswerModel`：声级每秒更新 ~20 次，走
/// `@Published` 会让整个刘海每帧重排；这里只是一把锁 + 两个 Float，渲染循环按需读取。
final class VoiceLevelBus: @unchecked Sendable {
    static let shared = VoiceLevelBus()

    private let lock = NSLock()
    private var envelope: Float = 0
    private var lastPush: CFTimeInterval = 0

    #if DEBUG
    /// 视觉 QA：FI_FAKE_VOICE=1 时合成「说话-停顿」式包络（demo 管线没有真音频，
    /// 折叠声纹条与光池的听声起伏靠它演出）。仅 DEBUG。
    private let synthesize = ProcessInfo.processInfo.environment["FI_FAKE_VOICE"] == "1"
    #endif

    /// 音频线程调用：一个 PCM16 chunk 的包络推进（快攻慢放）。
    func push(pcm16 data: Data) {
        var peak: Int32 = 0
        data.withUnsafeBytes { raw in
            for v in raw.bindMemory(to: Int16.self) {
                let a = abs(Int32(v))
                if a > peak { peak = a }
            }
        }
        // 语音常态峰值 ~3000–12000；归一后柔化顶部。
        let level = min(1, Float(peak) / 11000)
        lock.lock()
        envelope = max(level, envelope * 0.82)
        lastPush = CACurrentMediaTime()
        lock.unlock()
    }

    /// 渲染线程读取：流一停就在 ~0.4s 内静默（指数衰减），不会挂着残响。
    func level(at now: CFTimeInterval) -> Float {
        #if DEBUG
        if synthesize {
            // 短语（~带停顿）× 音节起伏，近似真实语音的包络形状。
            let phrase: Double = sin(now * 0.9) > -0.25 ? 1 : 0
            let syllable = pow(abs(sin(now * 2.1) * sin(now * 3.7)), 1.2)
            return Float(phrase * (0.20 + 0.80 * syllable))
        }
        #endif
        lock.lock()
        let env = envelope
        let age = now - lastPush
        lock.unlock()
        guard age < 2 else { return 0 }
        return env * Float(exp(-max(0, age - 0.08) * 6))
    }
}

// MARK: - Luma view

/// The light-field host. Sits between `NotchSurfaceView` (obsidian body) and the content,
/// masked to the same slab path, compositing additively over the black.
final class NotchLumaView: NSView {
    private let metalLayer = CAMetalLayer()
    private let maskLayer = CAShapeLayer()
    private var device: MTLDevice?
    private var queue: MTLCommandQueue?
    private var pipeline: MTLRenderPipelineState?
    private var link: CADisplayLink?
    private var proxy: LumaProxy?
    private let t0 = CACurrentMediaTime()

    // Card geometry (view coords), mirrored from NotchView.applyLayout.
    private var cardRect: CGRect = .zero
    private var slabPath: CGPath?

    // State targets (set by NotchView.refresh) and shown values (lerped per frame on the
    // render clock, so state changes glide instead of snapping).
    private var energyTarget: Float = 0.10
    private var energyShown: Float = 0.10
    private var tintTarget = SIMD3<Float>(0.55, 0.62, 0.85)
    private var tintShown = SIMD3<Float>(0.55, 0.62, 0.85)
    private var scanTarget: Float = 0
    private var scanShown: Float = 0
    private var stripTarget: Float = 0       // 折叠声纹条：录音中=1（展开时 shader 内自行让位）
    private var stripShown: Float = 0
    private var depthShown: Float = 0        // morph progress (set directly by applyLayout)
    private var flow: Float = 0              // token-arrival pulse, decays
    private var active = false               // state says "worth animating"
    private var lastStatus: AnswerModel.Status = .ready
    private var lastRecording = false

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    private struct Uniforms {
        var time: Float
        var res: SIMD2<Float>
        var cardMin: SIMD2<Float>
        var cardMax: SIMD2<Float>
        var tint: SIMD3<Float>
        var energy: Float
        var voice: Float
        var scan: Float
        var depth: Float
        var flow: Float
        var strip: Float
        var scale: Float   // 设备像素比：声纹条以物理 2pt 为准，不随卡片高度缩放
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        guard let dev = MTLCreateSystemDefaultDevice(),
              let q = dev.makeCommandQueue(),
              let lib = try? dev.makeLibrary(source: Self.shader, options: nil),
              let vfn = lib.makeFunction(name: "luma_vertex"),
              let ffn = lib.makeFunction(name: "luma_fragment") else {
            isHidden = true   // Metal 不可用（罕见）：优雅退回纯静态黑曜石
            return
        }
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vfn
        desc.fragmentFunction = ffn
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
        guard let state = try? dev.makeRenderPipelineState(descriptor: desc) else {
            isHidden = true
            return
        }
        device = dev
        queue = q
        pipeline = state

        metalLayer.device = dev
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = false
        metalLayer.backgroundColor = .clear
        layer?.addSublayer(metalLayer)
        layer?.mask = maskLayer
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    // MARK: Geometry (from NotchView.applyLayout — same values the surface draws with)

    func setSlab(cardRect: CGRect, topRadius: CGFloat, bottomRadius: CGFloat, depth: CGFloat) {
        self.cardRect = cardRect
        depthShown = Float(depth)
        let path = NotchShape.cgPath(in: cardRect, topRadius: topRadius, bottomRadius: bottomRadius)
        slabPath = path
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        maskLayer.path = path
        metalLayer.frame = bounds
        let scale = window?.backingScaleFactor ?? 2
        metalLayer.contentsScale = scale
        let w = max(1, bounds.width * scale), h = max(1, bounds.height * scale)
        if metalLayer.drawableSize != CGSize(width: w, height: h) {
            metalLayer.drawableSize = CGSize(width: w, height: h)
        }
        CATransaction.commit()
        updateRunning()
    }

    // MARK: State (from NotchView.refresh)

    func setState(_ status: AnswerModel.Status, recording: Bool) {
        lastStatus = status
        lastRecording = recording
        // 声纹条：正在录音（聆听面试官）时点亮——折叠时是唯一的「在听」光信号，
        // 展开后由光池接棒（shader 里乘 1-depth 交接）。
        stripTarget = recording ? 1 : 0
        switch status {
        case .ready:
            energyTarget = recording ? 0.22 : 0.11
            tintTarget = SIMD3(0.55, 0.62, 0.85)      // cool graphite breath
            scanTarget = 0
        case .listening:
            energyTarget = 0.34
            tintTarget = SIMD3(0.47, 0.61, 1.00)      // brand accent — voice adds the rest
            scanTarget = 0
        case .thinking:
            energyTarget = 0.60
            tintTarget = SIMD3(0.47, 0.61, 1.00)
            scanTarget = 1                            // the focus sweep
        case .streaming:
            energyTarget = 0.46
            tintTarget = SIMD3(0.55, 0.68, 1.00)
            scanTarget = 0
        case .presenting:
            energyTarget = 0.20
            tintTarget = SIMD3(0.50, 0.63, 0.98)
            scanTarget = 0
        case .error:
            energyTarget = 0.30
            tintTarget = SIMD3(1.00, 0.55, 0.22)      // warm amber, never alarm-red
            scanTarget = 0
        }
        updateRunning()
    }

    /// A token just arrived (streaming delta) — one soft pulse through the pool.
    func pulse() {
        flow = min(1.2, flow + 0.55)
        updateRunning()
    }

    // MARK: Run/pause — the field costs zero when there is nothing to show

    private var needsMotion: Bool {
        guard window != nil, !isHidden else { return false }
        if reduceMotion { return false }
        // 有戏可演：展开着、录着音、或不在纯待机；以及所有过渡尚未收敛。
        let stateWorth = depthShown > 0.02 || lastRecording || lastStatus != .ready
        let settling = abs(energyShown - energyTarget) > 0.004 || flow > 0.01
            || abs(scanShown - scanTarget) > 0.01 || abs(stripShown - stripTarget) > 0.01
        return stateWorth || settling
    }

    private func updateRunning() {
        guard pipeline != nil else { return }
        if reduceMotion {
            // 定格：渲染一帧当前状态（能量直接到位），随后保持暂停。
            energyShown = energyTarget
            tintShown = tintTarget
            scanShown = scanTarget
            stripShown = stripTarget
            renderFrame(now: t0 + 1)   // 固定时刻 → 确定性的静帧
            link?.isPaused = true
            return
        }
        if needsMotion {
            if link == nil {
                let p = LumaProxy(self)
                proxy = p
                link = displayLink(target: p, selector: #selector(LumaProxy.tick))
                link?.add(to: .main, forMode: .common)
            }
            link?.isPaused = false
        }
        // 不主动在这里暂停：tick 收敛后自会暂停（见 step()），避免中途硬切。
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { link?.isPaused = true } else { updateRunning() }
    }

    fileprivate func step() {
        let now = CACurrentMediaTime()
        // Glide uniforms.
        energyShown += (energyTarget - energyShown) * 0.07
        scanShown += (scanTarget - scanShown) * 0.09
        stripShown += (stripTarget - stripShown) * 0.10
        tintShown += (tintTarget - tintShown) * 0.07
        flow *= 0.90
        renderFrame(now: now)
        // 折叠时只有声纹条在动：30fps 足矣；展开的完整光场用满帧。
        link?.preferredFrameRateRange = depthShown < 0.05
            ? CAFrameRateRange(minimum: 24, maximum: 30, preferred: 30)
            : CAFrameRateRange(minimum: 48, maximum: 60, preferred: 60)
        if !needsMotion {
            // 收敛后渲染最后一帧全黑（能量已趋近待机值）再睡，保证 seam 纯黑。
            link?.isPaused = true
        }
    }

    private func renderFrame(now: CFTimeInterval) {
        guard let pipeline, let queue,
              cardRect.width > 1,
              let drawable = metalLayer.nextDrawable(),
              let cmd = queue.makeCommandBuffer() else { return }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }

        let scale = Float(metalLayer.contentsScale)
        var u = Uniforms(
            time: Float(now - t0),
            res: SIMD2(Float(metalLayer.drawableSize.width), Float(metalLayer.drawableSize.height)),
            cardMin: SIMD2(Float(cardRect.minX) * scale, Float(cardRect.minY) * scale),
            cardMax: SIMD2(Float(cardRect.maxX) * scale, Float(cardRect.maxY) * scale),
            tint: tintShown,
            energy: energyShown,
            voice: VoiceLevelBus.shared.level(at: now),
            scan: scanShown,
            depth: depthShown,
            flow: flow,
            strip: stripShown,
            scale: scale
        )
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
    }

    deinit { link?.invalidate() }

    // MARK: Shader

    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;

    struct VSOut { float4 pos [[position]]; };

    vertex VSOut luma_vertex(uint vid [[vertex_id]]) {
        float2 p = float2((vid << 1) & 2, vid & 2);
        VSOut o;
        o.pos = float4(p * 2.0 - 1.0, 0.0, 1.0);
        return o;
    }

    struct Uniforms {
        float  time;
        float2 res;
        float2 cardMin;
        float2 cardMax;
        float3 tint;
        float  energy;
        float  voice;
        float  scan;
        float  depth;
        float  flow;
        float  strip;
        float  scale;
    };

    float lhash(float2 p) {
        p = fract(p * float2(123.34, 345.45));
        p += dot(p, p + 34.345);
        return fract(p.x * p.y);
    }

    float lnoise(float2 p) {
        float2 i = floor(p);
        float2 f = fract(p);
        float2 u = f * f * (3.0 - 2.0 * f);
        return mix(mix(lhash(i), lhash(i + float2(1, 0)), u.x),
                   mix(lhash(i + float2(0, 1)), lhash(i + float2(1, 1)), u.x), u.y);
    }

    fragment float4 luma_fragment(VSOut in [[stage_in]], constant Uniforms& U [[buffer(0)]]) {
        // p = 0…1 inside the card (top-left origin, matching the flipped view).
        float2 span = max(U.cardMax - U.cardMin, float2(1.0));
        float2 p = (in.pos.xy - U.cardMin) / span;
        if (p.x < 0.0 || p.x > 1.0 || p.y < 0.0 || p.y > 1.0) { return float4(0); }

        float T = U.time;
        float aspect = span.x / span.y;
        float2 w = float2(p.x * aspect, p.y);

        // ① Screen-light pool along the lower face — the machined glass catching the display's
        //    glow. Breathes slowly on its own; the interviewer's voice makes it swell.
        float pool = exp(-(1.0 - p.y) * 3.4);
        pool *= 0.62 + 0.20 * sin(T * 0.55 + p.x * 2.3) + 0.18 * sin(T * 0.23 + 1.7);
        pool *= smoothstep(0.0, 0.10, p.x) * (1.0 - smoothstep(0.90, 1.0, p.x));
        pool *= 0.55 + 1.5 * U.voice;

        // ② Caustic drift — one slow warped current through the body, biased to the lower half.
        float2 q = float2(lnoise(w * 1.3 + float2(0.0, T * 0.045)),
                          lnoise(w * 1.3 + float2(3.7, -T * 0.038)));
        float ca = lnoise(w * 1.8 + q * 1.6 + float2(T * 0.02, 0.0));
        ca = smoothstep(0.52, 0.95, ca) * smoothstep(0.18, 0.70, p.y);

        // ③ Thinking sweep — a soft band of focus crossing the slab, like attention moving.
        float sx = fract(T * 0.30);
        float band = exp(-pow((p.x - mix(-0.25, 1.25, sx)) * 7.5, 2.0));
        float sweep = band * U.scan * smoothstep(0.15, 0.6, p.y);

        // ④ Token pulse — streaming deltas ripple through the pool from the left.
        float fx = fract(T * 0.9);
        float ripple = exp(-pow((p.x - fx) * 4.0, 2.0)) * U.flow * exp(-(1.0 - p.y) * 2.5);

        float3 body = U.tint * (pool * 0.34 + ca * 0.13 + sweep * 0.22 + ripple * 0.18) * U.energy;

        // Seam guard: top third stays essentially black so the slab keeps fusing with the
        // hardware cutout; collapsed (depth→0) dims the whole field to a whisper.
        body *= smoothstep(0.04, 0.38, p.y);
        body *= mix(0.30, 1.0, U.depth);

        // ⑤ Voiceprint strip — 录音中，折叠石板的下唇亮起一条 ~2pt 的声纹微光：两簇
        //    反向行波相乘出「语音包络」形，振幅吃 `voice`，静音时只剩极淡的持光
        //    （armed 的证明）。展开时乘 (1-depth) 让位给内部光池；物理宽度用像素
        //    标定（scale），不随卡片高度改变。避开圆角区，两端羽化。
        float dBottom = (1.0 - p.y) * span.y / max(U.scale, 1.0);   // 距下缘（pt）
        float lip = smoothstep(3.2, 0.8, dBottom);
        // 低频双波拍频 → 4–8 个缓慢行进的声浪瓣（高频版本读起来像 LED 珠链）。
        float wave = 0.45 + 0.55 * sin(w.x * 9.0 + T * 5.0) * sin(w.x * 3.4 - T * 3.1);
        float ends = smoothstep(0.015, 0.09, p.x) * (1.0 - smoothstep(0.91, 0.985, p.x));
        float3 stripCol = U.tint * lip * wave * ends
                        * (0.14 + 1.30 * U.voice) * U.strip * (1.0 - U.depth) * 2.0;

        float3 col = body + stripCol;

        // Triangular-PDF dither so the dim gradients never band.
        float dn = lhash(in.pos.xy) + lhash(in.pos.xy + 13.1) - 1.0;
        col = clamp(col + dn / 255.0, 0.0, 0.85);

        // Premultiplied over the black slab: source-over ≈ additive here（col ≤ a 保持
        // 预乘合法，越界会在合成器里出脏亮）。
        float a = clamp(max(col.r, max(col.g, col.b)), 0.0, 0.85);
        return float4(col, a);
    }
    """
}

private final class LumaProxy {
    weak var owner: NotchLumaView?
    init(_ o: NotchLumaView) { owner = o }
    @objc func tick() { owner?.step() }
}
