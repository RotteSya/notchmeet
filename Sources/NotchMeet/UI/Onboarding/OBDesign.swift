import AppKit
import SwiftUI

// The onboarding design system. Every primitive here exists to replace a "generic"
// tell from the old build: flat periwinkle gradient buttons, blurry colored glows,
// a card that blended into its own background. The rule throughout is restraint —
// material and a single crisp edge of light, never decoration for its own sake.

// MARK: - Theme

enum OB {
    static let bg       = Color(red: 0.024, green: 0.027, blue: 0.043) // #06070b
    static let accent   = Color(red: 0.490, green: 0.635, blue: 1.000) // #7DA2FF
    static let accentHi = Color(red: 0.640, green: 0.745, blue: 1.000) // top sheen
    static let accentLo = Color(red: 0.345, green: 0.470, blue: 0.910) // grounded edge/shadow
    static let ink      = Color(red: 0.961, green: 0.965, blue: 0.980)
    static let inkDeep  = Color(red: 0.043, green: 0.055, blue: 0.094) // text on accent

    /// A spring used for every step transition and control, so motion feels unified.
    static let spring = Animation.spring(response: 0.46, dampingFraction: 0.82)
    static let springSnappy = Animation.spring(response: 0.34, dampingFraction: 0.78)

    static func icon() -> NSImage? {
        if let p = Bundle.main.path(forResource: "AppIcon", ofType: "png"),
           let img = NSImage(contentsOfFile: p) { return img }
        let cwd = FileManager.default.currentDirectoryPath
        return NSImage(contentsOfFile: cwd + "/Resources/AppIcon.png")
    }
}

// MARK: - Surfaces

/// A floating glass panel: faint top-lit sheen, a hairline that brightens at the top
/// edge (light falling from above), and an optional layered drop shadow for elevation.
struct OBSurface: ViewModifier {
    var cornerRadius: CGFloat = 14
    var fill: Double = 0.22      // base darkness of the glass
    var elevated: Bool = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.black.opacity(fill))
                    .overlay(
                        LinearGradient(colors: [.white.opacity(0.06), .white.opacity(0.0)],
                                       startPoint: .top, endPoint: .bottom)
                            .blendMode(.plusLighter)
                            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(colors: [.white.opacity(0.18), .white.opacity(0.05)],
                                       startPoint: .top, endPoint: .bottom),
                        lineWidth: 0.75)
            )
            .shadow(color: .black.opacity(elevated ? 0.45 : 0), radius: elevated ? 24 : 0, y: elevated ? 14 : 0)
            .shadow(color: .black.opacity(elevated ? 0.28 : 0), radius: elevated ? 3 : 0, y: elevated ? 1 : 0)
    }
}

extension View {
    func obSurface(cornerRadius: CGFloat = 14, fill: Double = 0.22, elevated: Bool = false) -> some View {
        modifier(OBSurface(cornerRadius: cornerRadius, fill: fill, elevated: elevated))
    }
}

// MARK: - Buttons

/// The prominent call to action. A convex accent key: bright top sheen, a hairline of
/// light on the top edge, a grounded (not blurry) shadow, and a spring on press.
struct OBPrimaryButton: View {
    let title: String
    var minWidth: CGFloat = 0
    let action: () -> Void
    @State private var hovering = false

    init(_ title: String, minWidth: CGFloat = 0, action: @escaping () -> Void) {
        self.title = title; self.minWidth = minWidth; self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13.5, weight: .semibold))
                .tracking(0.2)
                .foregroundStyle(OB.inkDeep)
                .frame(minWidth: minWidth)
                .padding(.horizontal, 22).padding(.vertical, 9.5)
        }
        .buttonStyle(OBKeyStyle(hovering: hovering))
        .onHover { h in withAnimation(OB.springSnappy) { hovering = h } }
    }
}

private struct OBKeyStyle: ButtonStyle {
    var hovering: Bool
    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        return configuration.label
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(LinearGradient(colors: [OB.accentHi, OB.accent], startPoint: .top, endPoint: .bottom))
                    .overlay(   // top-edge specular hairline
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .strokeBorder(LinearGradient(colors: [.white.opacity(0.65), .white.opacity(0.0), OB.accentLo.opacity(0.5)],
                                                         startPoint: .top, endPoint: .bottom), lineWidth: 0.75)
                    )
                    .brightness(hovering ? 0.05 : 0)
            )
            .shadow(color: OB.accentLo.opacity(hovering ? 0.5 : 0.38), radius: hovering ? 14 : 10, y: hovering ? 7 : 5)
            .shadow(color: .black.opacity(0.25), radius: 1, y: 1)
            .scaleEffect(pressed ? 0.97 : 1)
            .animation(OB.springSnappy, value: pressed)
    }
}

/// Quiet, hairline-glass secondary action (Back).
struct OBGhostButton: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false
    init(_ title: String, action: @escaping () -> Void) { self.title = title; self.action = action }

    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 13, weight: .medium))
                .foregroundStyle(OB.ink.opacity(hovering ? 0.95 : 0.75))
                .padding(.horizontal, 18).padding(.vertical, 9.5)
        }
        .buttonStyle(OBGhostStyle(hovering: hovering))
        .onHover { h in withAnimation(OB.springSnappy) { hovering = h } }
    }
}

private struct OBGhostStyle: ButtonStyle {
    var hovering: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Color.white.opacity(hovering ? 0.10 : 0.06))
                    .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(Color.white.opacity(hovering ? 0.18 : 0.11), lineWidth: 0.75))
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(OB.springSnappy, value: configuration.isPressed)
    }
}

/// Barely-there text button (Skip / Replay), with an icon option.
struct OBTextButton: View {
    let title: String
    var systemImage: String? = nil
    var tint: Color = OB.ink.opacity(0.5)
    let action: () -> Void
    @State private var hovering = false
    init(_ title: String, systemImage: String? = nil, tint: Color = OB.ink.opacity(0.5), action: @escaping () -> Void) {
        self.title = title; self.systemImage = systemImage; self.tint = tint; self.action = action
    }
    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let s = systemImage { Image(systemName: s).font(.system(size: 11, weight: .semibold)) }
                Text(title).font(.system(size: 12.5, weight: .medium))
            }
            .foregroundStyle(hovering ? tint.opacity(1) : tint)
            .opacity(hovering ? 1 : 0.85)
            .padding(.horizontal, 8).padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Progress rail

/// Five segments: filled behind you, an elongated lit pill for the step you're on,
/// hairline ahead. Width + fill spring as a unit so the rail flows with the step.
struct OBProgressRail: View {
    let step: Int
    let total: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<total, id: \.self) { i in
                Capsule(style: .continuous)
                    .fill(i <= step ? AnyShapeStyle(LinearGradient(colors: [OB.accentHi, OB.accent], startPoint: .leading, endPoint: .trailing))
                                    : AnyShapeStyle(Color.white.opacity(0.14)))
                    .frame(width: i == step ? 26 : 7, height: 6)
                    .shadow(color: i == step ? OB.accent.opacity(0.55) : .clear, radius: 5, y: 0)
            }
        }
        .animation(OB.spring, value: step)
    }
}

// MARK: - Kicker

/// Small uppercase section label with a leading tick of accent.
struct OBKicker: View {
    let text: String
    var body: some View {
        HStack(spacing: 7) {
            Capsule().fill(OB.accent).frame(width: 14, height: 2.5)
                .shadow(color: OB.accent.opacity(0.6), radius: 3)
            Text(text).font(.system(size: 11, weight: .semibold)).tracking(1.5)
                .foregroundStyle(OB.accent).textCase(.uppercase)
        }
    }
}

// MARK: - Hero mark

enum OBHeroVariant { case welcome, done }

/// The app mark, presented with intent: a real contact shadow and a single thin ring
/// of light (not a blurry colored halo), breathing slowly. No sparkle. The `done`
/// variant grafts a refined check badge sprung in at the corner.
struct OBHeroIcon: View {
    var size: CGFloat
    var variant: OBHeroVariant
    @State private var appeared = false

    var body: some View {
        TimelineView(.animation) { ctx in
            let phase = ctx.date.timeIntervalSinceReferenceDate
            let bob = sin(phase * 0.9) * 2.2                  // gentle vertical float
            let breathe = 1 + sin(phase * 0.9) * 0.012        // paired breathing scale

            ZStack {
                // grounded soft shadow that tracks the float
                Ellipse()
                    .fill(Color.black.opacity(0.5))
                    .frame(width: size * 0.82, height: size * 0.18)
                    .blur(radius: 12)
                    .offset(y: size * 0.62 - bob * 0.5)
                    .scaleEffect(1 - bob * 0.01)

                iconBody
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.235, style: .continuous))
                    .overlay(   // thin ring of light
                        RoundedRectangle(cornerRadius: size * 0.235, style: .continuous)
                            .strokeBorder(LinearGradient(colors: [.white.opacity(0.5), .white.opacity(0.05)],
                                                         startPoint: .top, endPoint: .bottom), lineWidth: 1)
                    )
                    .shadow(color: OB.accent.opacity(0.28), radius: 26, y: 12)
                    .shadow(color: .black.opacity(0.4), radius: 6, y: 3)
                    .scaleEffect(breathe)
                    .offset(y: bob)
                    .overlay(alignment: .bottomTrailing) { if variant == .done { checkBadge } }
            }
            .scaleEffect(appeared ? 1 : 0.82)
            .opacity(appeared ? 1 : 0)
        }
        .frame(width: size * 1.2, height: size * 1.5)
        .onAppear { withAnimation(OB.spring.delay(0.05)) { appeared = true } }
    }

    @ViewBuilder private var iconBody: some View {
        if let img = OB.icon() {
            Image(nsImage: img).resizable().scaledToFit()
        } else {
            RoundedRectangle(cornerRadius: size * 0.235, style: .continuous)
                .fill(LinearGradient(colors: [OB.accentHi, OB.accentLo], startPoint: .top, endPoint: .bottom))
        }
    }

    private var checkBadge: some View {
        Image(systemName: "checkmark")
            .font(.system(size: size * 0.17, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: size * 0.36, height: size * 0.36)
            .background(
                Circle().fill(LinearGradient(colors: [OB.accentHi, OB.accentLo], startPoint: .top, endPoint: .bottom))
                    .overlay(Circle().strokeBorder(.white.opacity(0.4), lineWidth: 0.75))
            )
            .overlay(Circle().strokeBorder(OB.bg, lineWidth: 3))
            .shadow(color: OB.accentLo.opacity(0.5), radius: 8, y: 3)
            .offset(x: size * 0.10, y: size * 0.10)
            .transition(.scale.combined(with: .opacity))
    }
}

// MARK: - Finale CTA

/// The onboarding finale button — bigger and more present than `OBPrimaryButton`, with a
/// slow periodic light sweep that draws the eye to the one action that matters. Restrained:
/// the sheen passes once every few seconds, never a constant shimmer.
struct OBStartButton: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false
    init(_ title: String, action: @escaping () -> Void) { self.title = title; self.action = action }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(OB.inkDeep)
                .padding(.horizontal, 32).padding(.vertical, 13)
        }
        .buttonStyle(OBStartStyle(hovering: hovering))
        .onHover { h in withAnimation(OB.springSnappy) { hovering = h } }
    }
}

private struct OBStartStyle: ButtonStyle {
    var hovering: Bool
    private let radius: CGFloat = 14

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        return configuration.label
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(LinearGradient(colors: [OB.accentHi, OB.accent], startPoint: .top, endPoint: .bottom))
                    .overlay(   // top-edge specular hairline
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .strokeBorder(LinearGradient(colors: [.white.opacity(0.7), .white.opacity(0.0), OB.accentLo.opacity(0.55)],
                                                         startPoint: .top, endPoint: .bottom), lineWidth: 0.75)
                    )
                    .overlay { sheen }
                    .brightness(hovering ? 0.05 : 0)
            )
            .shadow(color: OB.accentLo.opacity(hovering ? 0.62 : 0.48), radius: hovering ? 22 : 17, y: hovering ? 9 : 7)
            .shadow(color: .black.opacity(0.25), radius: 1, y: 1)
            .scaleEffect(pressed ? 0.97 : 1)
            .animation(OB.springSnappy, value: pressed)
    }

    /// A soft highlight band that sweeps left→right once per cycle, then rests.
    private var sheen: some View {
        GeometryReader { geo in
            TimelineView(.animation) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate
                let cycle = 3.6, sweep = 1.0
                let m = t.truncatingRemainder(dividingBy: cycle)
                let x = min(m / sweep, 1)                       // 0…1 during the sweep, parked at 1 after
                let w = geo.size.width
                Rectangle()
                    .fill(LinearGradient(colors: [.clear, .white.opacity(0.5), .clear], startPoint: .leading, endPoint: .trailing))
                    .frame(width: w * 0.45)
                    .offset(x: -w * 0.45 + x * w * 1.45)
                    .opacity(m <= sweep ? 1 : 0)
                    .blendMode(.plusLighter)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .allowsHitTesting(false)
    }
}
