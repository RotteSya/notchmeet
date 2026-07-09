import AppKit
import MetalKit

// A living, GPU-rendered backdrop for the settings window — the antidote to the flat
// warm-charcoal plane that reads as "AI slop". A deep, slow, double domain-warped fBm
// aurora in the brand blues, with light pooling in the upper-left behind the sidebar rail
// and falling away to near-black under the reading column so type stays crisp. Triangular-
// PDF dithering kills the banding. Pure Metal + MetalKit — no third-party anything. Runs
// only while the window is on screen (paused otherwise) so an idle settings window is free.

final class SettingsBackdrop: NSView {
    private let inner: NSView

    override init(frame frameRect: NSRect) {
        if let device = MTLCreateSystemDefaultDevice(), let mtk = AuroraSettingsView(device: device) {
            inner = mtk
        } else {
            inner = AuroraFallback()
        }
        super.init(frame: frameRect)
        inner.frame = bounds
        inner.autoresizingMask = [.width, .height]
        addSubview(inner)
        wantsLayer = true
        layer?.isOpaque = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Pause the GPU when the window is not visible.
    func setRunning(_ running: Bool) { (inner as? AuroraSettingsView)?.isPaused = !running }
}

// MARK: - Metal view

private final class AuroraSettingsView: MTKView {
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let start = CACurrentMediaTime()

    private struct Uniforms { var time: Float; var res: SIMD2<Float> }

    init?(device: MTLDevice) {
        guard let queue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: Self.source, options: nil),
              let vfn = library.makeFunction(name: "set_aurora_vertex"),
              let ffn = library.makeFunction(name: "set_aurora_fragment") else { return nil }

        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vfn
        desc.fragmentFunction = ffn
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
        guard let state = try? device.makeRenderPipelineState(descriptor: desc) else { return nil }

        self.commandQueue = queue
        self.pipeline = state
        super.init(frame: .zero, device: device)

        colorPixelFormat = .bgra8Unorm
        framebufferOnly = true
        enableSetNeedsDisplay = false
        isPaused = false
        preferredFramesPerSecond = 60
        layer?.isOpaque = true
        clearColor = MTLClearColor(red: 0.020, green: 0.023, blue: 0.038, alpha: 1)
        wantsLayer = true
    }

    required init(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        guard !isPaused,
              let drawable = currentDrawable,
              let pass = currentRenderPassDescriptor,
              let cmd = commandQueue.makeCommandBuffer(),
              let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }

        let size = drawableSize
        var u = Uniforms(time: Float(CACurrentMediaTime() - start),
                         res: SIMD2(Float(max(size.width, 1)), Float(max(size.height, 1))))
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
    }

    // Compiled at runtime — no .metallib / build-system support needed.
    private static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct VSOut { float4 pos [[position]]; float2 uv; };

    vertex VSOut set_aurora_vertex(uint vid [[vertex_id]]) {
        float2 p = float2((vid << 1) & 2, vid & 2);
        VSOut o;
        o.pos = float4(p * 2.0 - 1.0, 0.0, 1.0);
        o.uv  = float2(p.x, 1.0 - p.y);
        return o;
    }

    struct Uniforms { float time; float2 res; };

    float h21(float2 p) {
        p = fract(p * float2(123.34, 345.45));
        p += dot(p, p + 34.345);
        return fract(p.x * p.y);
    }
    float vnoise(float2 p) {
        float2 i = floor(p), f = fract(p);
        float2 u = f * f * (3.0 - 2.0 * f);
        float a = h21(i), b = h21(i + float2(1,0));
        float c = h21(i + float2(0,1)), d = h21(i + float2(1,1));
        return mix(mix(a,b,u.x), mix(c,d,u.x), u.y);
    }
    float fbm(float2 p) {
        float s = 0.0, a = 0.5;
        float2x2 m = float2x2(1.6, 1.2, -1.2, 1.6);
        for (int i = 0; i < 5; i++) { s += a * vnoise(p); p = m * p; a *= 0.5; }
        return s;
    }

    fragment float4 set_aurora_fragment(VSOut in [[stage_in]], constant Uniforms& U [[buffer(0)]]) {
        float aspect = U.res.x / U.res.y;
        float2 uv = in.uv;
        float2 p = float2(uv.x * aspect, uv.y) * 2.2;
        float t = U.time * 0.028;                       // deliberately slow — a calm utility surface

        // Double domain warp → organic, flowing cloud structure.
        float2 q = float2(fbm(p + float2(0.0, t)),
                          fbm(p + float2(5.2, 1.3) - t * 0.8));
        float2 r = float2(fbm(p + 2.6 * q + float2(1.7, 9.2) + t * 0.5),
                          fbm(p + 2.6 * q + float2(8.3, 2.8) - t * 0.6));
        float f = fbm(p + 2.4 * r);

        // Brand palette: near-black blue base → indigo → periwinkle, a whisper of cyan.
        float3 base   = float3(0.018, 0.021, 0.036);
        float3 indigo = float3(0.070, 0.098, 0.250);
        float3 peri   = float3(0.300, 0.400, 0.880);
        float3 cyan   = float3(0.220, 0.450, 0.700);

        float3 col = base;
        col = mix(col, indigo, smoothstep(0.12, 0.98, f));
        col = mix(col, peri,   smoothstep(0.62, 1.28, f) * (0.20 + 0.40 * r.x));
        col = mix(col, cyan,   smoothstep(0.66, 1.32, length(q)) * 0.14);

        // Light pools in the upper-left (behind the sidebar rail + title) and falls away to
        // near-black under the reading column — felt, not seen. Brightness is tied mostly to
        // the pool so the content stays a deep, calm obsidian rather than a visible nebula.
        float2 anchor = float2(0.13 * aspect, 0.07);
        float2 g = float2(uv.x * aspect, uv.y) - anchor;
        float pool = exp(-dot(g, g) * 1.8);
        col += peri * pool * 0.080;
        col *= 0.30 + 0.15 * f + 0.66 * pool;           // a touch more life in the framing margins

        // Gentle global vignette to seat the window chrome.
        float2 v = uv - 0.5;
        col *= mix(0.72, 1.06, smoothstep(0.9, 0.05, dot(v, v) * 1.8));

        // Triangular-PDF dither — the difference between "premium" and "banded".
        float dn = h21(in.pos.xy) + h21(in.pos.xy + 13.1) - 1.0;
        col += dn / 255.0;
        return float4(col, 1.0);
    }
    """
}

// MARK: - Fallback (no Metal device — rare on real Macs)

private final class AuroraFallback: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        wantsLayer = true
        let g = CAGradientLayer()
        g.type = .radial
        g.colors = [NSColor(srgbRed: 0.10, green: 0.13, blue: 0.30, alpha: 1).cgColor,
                    NSColor(srgbRed: 0.020, green: 0.023, blue: 0.038, alpha: 1).cgColor]
        g.startPoint = CGPoint(x: 0.16, y: 0.92)
        g.endPoint = CGPoint(x: 1.0, y: 0.0)
        g.frame = bounds
        g.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer = g
    }
}
