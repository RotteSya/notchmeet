import AppKit
import SwiftUI

enum SettingsPalette {
    static let window = Color(red: 0.064, green: 0.066, blue: 0.070)
    static let titlebar = Color(red: 0.072, green: 0.074, blue: 0.078)
    static let sidebar = Color(red: 0.055, green: 0.057, blue: 0.061)
    static let content = Color(red: 0.087, green: 0.088, blue: 0.091)
    static let field = Color.white.opacity(0.045)
    static let selection = Color.white.opacity(0.090)
    static let selectionHover = Color.white.opacity(0.055)
    static let primary = Color(red: 0.965, green: 0.965, blue: 0.950)
    static let secondary = Color.white.opacity(0.58)
    static let tertiary = Color.white.opacity(0.36)
    static let accent = Color(red: 0.18, green: 0.47, blue: 0.98)
    static let destructive = Color(red: 1.0, green: 0.31, blue: 0.27)
    static let rule = Color.white.opacity(0.095)
    static let fieldBorder = Color.white.opacity(0.13)

    static let windowNSColor = NSColor(srgbRed: 0.064, green: 0.066, blue: 0.070, alpha: 1)
    static let hairline: CGFloat = 0.5
    static let navigation = Animation.spring(response: 0.32, dampingFraction: 0.88)
    static let control = Animation.easeOut(duration: 0.16)
}

struct SettingsHairline: View {
    var vertical = false

    var body: some View {
        SettingsPalette.rule
            .frame(width: vertical ? SettingsPalette.hairline : nil,
                   height: vertical ? nil : SettingsPalette.hairline)
            .accessibilityHidden(true)
    }
}

struct SettingsPageTitle: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 24, weight: .semibold))
            .tracking(-0.35)
            .foregroundStyle(SettingsPalette.primary)
            .accessibilityAddTraits(.isHeader)
    }
}

struct SettingsSectionHeading: View {
    let title: String
    var help: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(SettingsPalette.primary)
            if let help {
                Text(help)
                    .font(.system(size: 12))
                    .foregroundStyle(SettingsPalette.secondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct SettingsButton: View {
    enum Kind { case primary, secondary, destructive, plain }

    let title: String
    var systemImage: String? = nil
    var kind: Kind = .secondary
    var tint: Color? = nil
    var minWidth: CGFloat = 0
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 11, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
            }
            .frame(minWidth: minWidth)
            .padding(.horizontal, kind == .plain ? 7 : 16)
            .padding(.vertical, kind == .plain ? 6 : 7.5)
            .contentShape(Rectangle())
        }
        .buttonStyle(SettingsButtonStyle(kind: kind, tint: tint, hovering: hovering))
        .onHover { value in
            withAnimation(SettingsPalette.control) { hovering = value }
        }
    }
}

private struct SettingsButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    let kind: SettingsButton.Kind
    let tint: Color?
    let hovering: Bool

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        return configuration.label
            .foregroundStyle(isEnabled ? foreground : SettingsPalette.tertiary)
            .background(background.opacity(pressed ? 0.72 : 1))
            .overlay {
                if kind != .plain {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(border, lineWidth: SettingsPalette.hairline)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .scaleEffect(pressed ? 0.985 : 1)
            .opacity(isEnabled ? 1 : 0.70)
            .animation(SettingsPalette.control, value: pressed)
    }

    private var foreground: Color {
        if let tint { return tint.opacity(hovering ? 1 : 0.84) }
        switch kind {
        case .primary: return Color.white
        case .secondary: return SettingsPalette.primary.opacity(hovering ? 1 : 0.86)
        case .destructive: return SettingsPalette.destructive.opacity(hovering ? 1 : 0.88)
        case .plain: return SettingsPalette.secondary.opacity(hovering ? 1 : 0.78)
        }
    }

    private var background: Color {
        if !isEnabled { return Color.white.opacity(0.04) }
        switch kind {
        case .primary: return SettingsPalette.accent.opacity(hovering ? 1 : 0.90)
        case .secondary: return Color.white.opacity(hovering ? 0.095 : 0.052)
        case .destructive: return SettingsPalette.destructive.opacity(hovering ? 0.12 : 0.055)
        case .plain: return Color.white.opacity(hovering ? 0.045 : 0)
        }
    }

    private var border: Color {
        if !isEnabled { return Color.white.opacity(0.08) }
        switch kind {
        case .primary: return Color.white.opacity(0.20)
        case .secondary: return Color.white.opacity(hovering ? 0.19 : 0.12)
        case .destructive: return SettingsPalette.destructive.opacity(hovering ? 0.72 : 0.48)
        case .plain: return Color.clear
        }
    }
}

struct SettingsFieldChrome: ViewModifier {
    let focused: Bool

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 10)
            .padding(.vertical, 7.5)
            .background(SettingsPalette.field)
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(focused ? SettingsPalette.accent.opacity(0.82) : SettingsPalette.fieldBorder,
                                  lineWidth: focused ? 1 : SettingsPalette.hairline)
            )
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .animation(SettingsPalette.control, value: focused)
    }
}

extension View {
    func settingsField(focused: Bool = false) -> some View {
        modifier(SettingsFieldChrome(focused: focused))
    }
}
