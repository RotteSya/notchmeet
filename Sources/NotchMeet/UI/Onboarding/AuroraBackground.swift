import SwiftUI
import MetalKit

// A living, GPU-rendered backdrop for onboarding — the real thing the old code only
// faked with a flat `RadialGradient` "fallback". A double domain-warped fBm aurora in
// the brand blues, kept deliberately deep and low-contrast so type stays crisp on top.
// Triangular-PDF dithering kills the gradient banding that screams "AI slop"; a soft
// top-center bloom aligns with the real notch above the window. Pure Metal + MetalKit —
// no third-party anything. `progress` (0…1 across the five steps) is eased on the GPU
// thread so the scene warms and brightens as the user advances.

struct AuroraBackground: NSViewRepresentable {
    var progress: Double

    func makeNSView(context: Context) -> NSView {
        if let device = MTLCreateSystemDefaultDevice(),
           let view = AuroraMTKView(device: device) {
            view.targetProgress = Float(progress)
            return view
        }
        return AuroraFallbackView()   // Metal unavailable (rare on real Macs)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? AuroraMTKView)?.targetProgress = Float(progress)
    }
}

// MARK: - Metal view

private final class AuroraMTKView: MTKView {
    var targetProgress: Float = 0
    private var shownProgress: Float = 0

    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let start = CACurrentMediaTime()

    private struct Uniforms { var time: Float; var res: SIMD2<Float>; var progress: Float }

    init?(device: MTLDevice) {
        guard let queue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: Self.source, options: nil),
              let vfn = library.makeFunction(name: "aurora_vertex"),
              let ffn = library.makeFunction(name: "aurora_fragment") else { return nil }

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
        isPaused = false
        enableSetNeedsDisplay = false
        preferredFramesPerSecond = 60
        layer?.isOpaque = true
        clearColor = MTLClearColor(red: 0.024, green: 0.027, blue: 0.043, alpha: 1)
        wantsLayer = true
    }

    required init(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        guard let drawable = currentDrawable,
              let pass = currentRenderPassDescriptor,
              let cmd = commandQueue.makeCommandBuffer(),
              let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }

        // Ease toward the target so per-step jumps glide rather than snap.
        shownProgress += (targetProgress - shownProgress) * 0.06

        let size = drawableSize
        var u = Uniforms(time: Float(CACurrentMediaTime() - start),
                         res: SIMD2(Float(max(size.width, 1)), Float(max(size.height, 1))),
                         progress: shownProgress)

        enc.setRenderPipelineState(pipeline)
        enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
    }

    // MARK: Shader (compiled at runtime — no .metallib / build-system support needed)

    private static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct VSOut { float4 pos [[position]]; float2 uv; };

    // Fullscreen triangle from vertex_id — no vertex buffer.
    vertex VSOut aurora_vertex(uint vid [[vertex_id]]) {
        float2 p = float2((vid << 1) & 2, vid & 2);
        VSOut o;
        o.pos = float4(p * 2.0 - 1.0, 0.0, 1.0);
        o.uv  = float2(p.x, 1.0 - p.y);
        return o;
    }

    struct Uniforms { float time; float2 res; float progress; };

    float hash21(float2 p) {
        p = fract(p * float2(123.34, 345.45));
        p += dot(p, p + 34.345);
        return fract(p.x * p.y);
    }

    float vnoise(float2 p) {
        float2 i = floor(p);
        float2 f = fract(p);
        float2 u = f * f * (3.0 - 2.0 * f);
        float a = hash21(i + float2(0.0, 0.0));
        float b = hash21(i + float2(1.0, 0.0));
        float c = hash21(i + float2(0.0, 1.0));
        float d = hash21(i + float2(1.0, 1.0));
        return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
    }

    float fbm(float2 p) {
        float s = 0.0, a = 0.5;
        float2x2 m = float2x2(1.6, 1.2, -1.2, 1.6);
        for (int i = 0; i < 5; i++) { s += a * vnoise(p); p = m * p; a *= 0.5; }
        return s;
    }

    fragment float4 aurora_fragment(VSOut in [[stage_in]], constant Uniforms& U [[buffer(0)]]) {
        float aspect = U.res.x / U.res.y;
        float2 uv = in.uv;
        float2 p = float2(uv.x * aspect, uv.y) * 2.4;
        float t = U.time * 0.05;

        // IQ-style double domain warp → organic, flowing cloud structure.
        float2 q = float2(fbm(p + float2(0.0, t)),
                          fbm(p + float2(5.2, 1.3) - t * 0.8));
        float2 r = float2(fbm(p + 3.0 * q + float2(1.7, 9.2) + t * 0.5),
                          fbm(p + 3.0 * q + float2(8.3, 2.8) - t * 0.6));
        float f = fbm(p + 2.5 * r);

        // Brand palette: near-black blue base → indigo → periwinkle, a whisper of cyan.
        float3 base   = float3(0.020, 0.024, 0.041);
        float3 indigo = float3(0.090, 0.120, 0.290);
        float3 peri   = float3(0.420, 0.520, 0.960);
        float3 cyan   = float3(0.260, 0.520, 0.760);

        float3 col = base;
        col = mix(col, indigo, smoothstep(0.05, 0.95, f));
        col = mix(col, peri,   smoothstep(0.45, 1.15, f) * (0.45 + 0.55 * r.x));
        col = mix(col, cyan,   smoothstep(0.55, 1.20, length(q)) * 0.30);
        col *= 0.52 + 0.48 * f;   // keep it deep — most of the frame is shadow

        // Soft bloom toward the notch (top-center), strengthening as steps advance.
        float2 g = float2((uv.x - 0.5) * aspect, uv.y + 0.04);
        float glow = exp(-dot(g, g) * 5.5);
        col += peri * glow * (0.05 + 0.06 * U.progress);

        // Vignette to seat the floating card.
        float2 v = uv - 0.5;
        col *= mix(0.66, 1.0, smoothstep(1.0, 0.18, dot(v, v) * 2.2));

        // Warm/brighten ever so slightly across the journey.
        col += float3(0.015, 0.018, 0.026) * U.progress;

        // Triangular-PDF dither — the difference between "premium" and "banded".
        float dn = hash21(in.pos.xy) + hash21(in.pos.xy + 13.1) - 1.0;
        col += dn / 255.0;

        return float4(col, 1.0);
    }
    """
}

// MARK: - Fallback (no Metal device)

private final class AuroraFallbackView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        wantsLayer = true
        let g = CAGradientLayer()
        g.type = .radial
        g.colors = [NSColor(srgbRed: 0.10, green: 0.13, blue: 0.30, alpha: 1).cgColor,
                    NSColor(srgbRed: 0.024, green: 0.027, blue: 0.043, alpha: 1).cgColor]
        g.startPoint = CGPoint(x: 0.5, y: 0.5)
        g.endPoint = CGPoint(x: 1.1, y: 1.1)
        g.frame = bounds
        g.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer = g
    }
}
