import SwiftUI

// Onboarding v2 的两个「时刻」：工作原理三拍动画、见面礼到账。
// 都是纯 SwiftUI 手绘（TimelineView 驱动），与 OBDesign 同一材质语言：
// 玻璃面板、一条高光边、克制的品牌光。Reduce Motion 时全部直接落位。

private var obReduceMotion: Bool {
    NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
}

// MARK: - How it works（三拍：提问 → 对稿 → 上刘海）

/// 三块玻璃卡横排，聚光灯每 2.4s 移到下一拍并循环；活动卡内的微型画面持续演出：
/// ① 波形在说话 ② 原稿被扫中一行 ③ 迷你刘海里答案逐行浮现。
struct OBHowItWorks: View {
    let t: OBStrings
    private let beat: Double = 2.4

    var body: some View {
        TimelineView(.animation) { ctx in
            let time = ctx.date.timeIntervalSinceReferenceDate
            let active = obReduceMotion ? 2 : Int(time / beat) % 3
            let local = time.truncatingRemainder(dividingBy: beat) / beat   // 0…1 within beat

            HStack(spacing: 10) {
                beatCard(0, active: active, title: t.howT1, desc: t.howD1) {
                    HowVoiceGlyph(phase: time, live: active == 0)
                }
                beatCard(1, active: active, title: t.howT2, desc: t.howD2) {
                    HowMatchGlyph(progress: active == 1 ? local : (active > 1 ? 1 : 0))
                }
                beatCard(2, active: active, title: t.howT3, desc: t.howD3) {
                    HowNotchGlyph(progress: active == 2 ? local : 0)
                }
            }
            .animation(OB.spring, value: active)
        }
        .frame(height: 190)
    }

    @ViewBuilder
    private func beatCard<G: View>(_ index: Int, active: Int, title: String, desc: String,
                                   @ViewBuilder glyph: () -> G) -> some View {
        let on = index == active
        VStack(spacing: 10) {
            ZStack { glyph() }
                .frame(width: 96, height: 74)
            Text(title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(on ? OB.ink : OB.ink.opacity(0.62))
            Text(desc)
                .font(.system(size: 10.5))
                .multilineTextAlignment(.center)
                .lineSpacing(1.5)
                .foregroundStyle(OB.ink.opacity(on ? 0.55 : 0.34))
                .frame(maxWidth: .infinity)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity)
        .obSurface(cornerRadius: 14, fill: on ? 0.30 : 0.16)
        .overlay(alignment: .top) {
            if on {
                Capsule().fill(OB.accent).frame(width: 26, height: 2.5)
                    .shadow(color: OB.accent.opacity(0.7), radius: 4)
                    .offset(y: -1)
            }
        }
        .scaleEffect(on ? 1.0 : 0.965)
        .opacity(on ? 1 : 0.8)
    }
}

/// ① 面试官提问：圆形徽章里的中心加权声浪。
private struct HowVoiceGlyph: View {
    let phase: Double
    let live: Bool

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(OB.accent.opacity(live ? 0.35 : 0.16), lineWidth: 1)
                .background(Circle().fill(OB.accent.opacity(live ? 0.10 : 0.05)))
            HStack(spacing: 2.5) {
                ForEach(0..<9, id: \.self) { i in
                    let x = Double(i) / 8
                    let env = sin(x * .pi)
                    let amp = live
                        ? 0.22 + 0.78 * env * (0.5 + 0.5 * sin(phase * 6 + Double(i) * 0.7))
                        : 0.16 + 0.18 * env
                    Capsule()
                        .fill(OB.accent.opacity(live ? 0.95 : 0.4))
                        .frame(width: 2.5, height: max(3, 30 * amp))
                }
            }
        }
        .frame(width: 62, height: 62)
    }
}

/// ② 对准原稿：一页稿纸，扫描线掠过，命中行亮起品牌色。
private struct HowMatchGlyph: View {
    let progress: Double   // 0…1（本拍内）

    var body: some View {
        let sweep = min(1, progress * 1.6)              // 扫描先行
        let hit = progress > 0.55                        // 后半拍命中
        VStack(spacing: 5) {
            ForEach(0..<4, id: \.self) { i in
                let hitRow = i == 2
                Capsule()
                    .fill(hitRow && hit ? OB.accent : Color.white.opacity(0.22))
                    .frame(width: hitRow ? 56 : [44, 50, 56, 38][i], height: 4)
                    .shadow(color: hitRow && hit ? OB.accent.opacity(0.7) : .clear, radius: 4)
                    .animation(OB.springSnappy, value: hit)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.black.opacity(0.35))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.75))
        )
        .overlay {
            // 扫描线
            GeometryReader { geo in
                Rectangle()
                    .fill(LinearGradient(colors: [.clear, OB.accent.opacity(0.5), .clear],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(height: 14)
                    .offset(y: (geo.size.height + 14) * sweep - 14)
                    .opacity(sweep < 1 ? 1 : 0)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .frame(width: 80)
    }
}

/// ③ 浮现在刘海：迷你屏幕顶端的黑色刘海板，答案行逐条点亮。
private struct HowNotchGlyph: View {
    let progress: Double

    var body: some View {
        VStack(spacing: 0) {
            // 屏幕顶边 + 刘海slab
            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.white.opacity(0.06))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.75))
                VStack(spacing: 4.5) {
                    UnevenRoundedRectangle(bottomLeadingRadius: 7, bottomTrailingRadius: 7)
                        .fill(Color.black.opacity(0.9))
                        .overlay(alignment: .bottomLeading) {
                            VStack(alignment: .leading, spacing: 3.5) {
                                answerLine(0, w: 44)
                                answerLine(1, w: 52)
                                answerLine(2, w: 34)
                            }
                            .padding(.leading, 8)
                            .padding(.bottom, 6)
                        }
                        .frame(width: 74, height: 34)
                        .shadow(color: OB.accent.opacity(progress > 0.1 ? 0.25 : 0), radius: 8, y: 3)
                    Spacer(minLength: 0)
                }
            }
            .frame(width: 88, height: 62)
        }
    }

    private func answerLine(_ i: Int, w: CGFloat) -> some View {
        let start = 0.18 + Double(i) * 0.22
        let f = max(0, min(1, (progress - start) / 0.2))
        return Capsule()
            .fill(OB.ink.opacity(0.85))
            .frame(width: w * f, height: 3)
            .frame(width: w, alignment: .leading)
            .opacity(f > 0 ? 1 : 0)
    }
}

// MARK: - Gift reveal（见面礼到账）

/// 环形扫满 + 数字弹升 + 到账瞬间一圈光尘。一次性演出（onAppear 起算），
/// 之后停在结果态；Reduce Motion 直接呈现结果。
struct OBGiftReveal: View {
    let minutes: Int
    let unit: String     // "分钟" / "分"
    @State private var start = Date()

    private let sweepDur = 1.35

    var body: some View {
        TimelineView(.animation) { ctx in
            let t = obReduceMotion ? sweepDur : ctx.date.timeIntervalSince(start)
            let p = easeOutCubic(min(1, max(0, t / sweepDur)))
            let landed = t >= sweepDur

            ZStack {
                // 光尘：到账瞬间从环沿迸出，1s 内散去。
                if !obReduceMotion, landed, t < sweepDur + 1.2 {
                    GiftDust(age: t - sweepDur)
                }

                Circle()
                    .stroke(Color.white.opacity(0.08), lineWidth: 9)
                Circle()
                    .trim(from: 0, to: p)
                    .stroke(
                        AngularGradient(colors: [OB.accentLo, OB.accent, OB.accentHi],
                                        center: .center, startAngle: .degrees(-90),
                                        endAngle: .degrees(270)),
                        style: StrokeStyle(lineWidth: 9, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .shadow(color: OB.accent.opacity(0.4 * p), radius: 10)

                VStack(spacing: 2) {
                    HStack(alignment: .lastTextBaseline, spacing: 4) {
                        Text("\(Int(Double(minutes) * p))")
                            .font(.system(size: 40, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                            .contentTransition(.numericText())
                        Text(unit)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(OB.ink.opacity(0.6))
                    }
                    Image(systemName: "gift.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(OB.accent)
                        .opacity(landed ? 1 : 0.35)
                        .scaleEffect(landed ? 1 : 0.8)
                        .animation(OB.springSnappy, value: landed)
                }
            }
            .frame(width: 150, height: 150)
            .scaleEffect(landed ? 1 : 0.99 + 0.01 * p)
        }
        .onAppear { start = Date() }
    }

    private func easeOutCubic(_ x: Double) -> Double { 1 - pow(1 - x, 3) }
}

/// 一次性的光尘环爆：24 粒确定性伪随机粒子，径向飞散、渐隐。
private struct GiftDust: View {
    let age: Double   // 0…1.2s

    var body: some View {
        Canvas { ctx, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let life = min(1, age / 1.1)
            for i in 0..<24 {
                var h = UInt64(i) &* 0x9E3779B97F4A7C15
                h ^= h >> 31
                let a = Double(h % 3600) / 3600 * 2 * .pi
                let speed = 46 + Double((h >> 8) % 40)                 // 46…86 pt
                let r = 66 + speed * easeOut(life)
                let size0 = 1.6 + Double((h >> 16) % 20) / 10          // 1.6…3.6 pt
                let alpha = (1 - life) * (0.5 + Double((h >> 24) % 50) / 100)
                let p = CGPoint(x: c.x + cos(a) * r, y: c.y + sin(a) * r)
                let dot = CGRect(x: p.x - size0 / 2, y: p.y - size0 / 2, width: size0, height: size0)
                let tint: Color = (h >> 32) % 3 == 0 ? .white : OB.accentHi
                ctx.opacity = alpha
                ctx.fill(Path(ellipseIn: dot), with: .color(tint))
            }
        }
        .allowsHitTesting(false)
    }

    private func easeOut(_ x: Double) -> Double { 1 - pow(1 - x, 2.2) }
}
