import SwiftUI

enum NotchPalette {
    static let background = Color.black
    static let primary = Color.white.opacity(0.96)
    static let secondary = Color.white.opacity(0.58)
    static let tertiary = Color.white.opacity(0.34)
    static let accent = Color(red: 0.18, green: 0.47, blue: 0.98)
    static let recording = Color(red: 1.0, green: 0.28, blue: 0.24)
    static let warning = Color(red: 1.0, green: 0.48, blue: 0.22)
    static let rule = Color.white.opacity(0.10)

    static let content = Animation.easeOut(duration: 0.18)
    static let control = Animation.easeOut(duration: 0.13)
}

struct NotchControlButton: View {
    let systemName: String
    let tint: Color
    let label: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(tint.opacity(hovering ? 1 : 0.82))
                .frame(width: 28, height: 24)
                .background(Color.white.opacity(hovering ? 0.085 : 0))
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(NotchPressStyle())
        .onHover { value in
            withAnimation(NotchPalette.control) { hovering = value }
        }
        .help(label)
        .accessibilityLabel(label)
    }
}

private struct NotchPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.95 : 1)
            .opacity(configuration.isPressed ? 0.72 : 1)
            .animation(reduceMotion ? nil : NotchPalette.control, value: configuration.isPressed)
    }
}
