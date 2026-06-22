import SwiftUI

/// Compact status instrument shared by the collapsed notch and expanded header.
/// Recording is always represented by the outer red ring; the inner mark communicates
/// pipeline state without relying on color alone.
struct NotchStatusMark: View {
    let status: AnswerModel.Status
    let recording: Bool
    let activity: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var listeningPulse = false

    var body: some View {
        ZStack {
            if recording {
                Circle()
                    .stroke(NotchPalette.recording.opacity(0.88), lineWidth: 1)
                    .frame(width: 13, height: 13)
            }
            statusCore
        }
        .frame(width: 14, height: 14)
        .accessibilityHidden(true)
        .onAppear {
            if !reduceMotion { listeningPulse = true }
        }
    }

    @ViewBuilder private var statusCore: some View {
        switch status {
        case .ready:
            Circle()
                .fill(NotchPalette.tertiary)
                .frame(width: 4.5, height: 4.5)

        case .listening:
            Circle()
                .fill(NotchPalette.recording)
                .frame(width: 5.5, height: 5.5)
                .scaleEffect(reduceMotion ? 1 : (listeningPulse ? 1.08 : 0.78))
                .opacity(reduceMotion ? 1 : (listeningPulse ? 1 : 0.62))
                .animation(
                    reduceMotion ? nil : .easeInOut(duration: 1.05).repeatForever(autoreverses: true),
                    value: listeningPulse
                )

        case .thinking:
            Image(systemName: "ellipsis")
                .font(.system(size: 7.5, weight: .bold))
                .foregroundStyle(NotchPalette.accent)

        case .streaming:
            Capsule(style: .continuous)
                .fill(NotchPalette.accent)
                .frame(width: activity.isMultiple(of: 2) ? 10 : 6, height: 2.5)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: activity)

        case .presenting:
            Image(systemName: "checkmark")
                .font(.system(size: 7.5, weight: .bold))
                .foregroundStyle(NotchPalette.accent)

        case .error:
            Image(systemName: "exclamationmark")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(NotchPalette.warning)
        }
    }
}
