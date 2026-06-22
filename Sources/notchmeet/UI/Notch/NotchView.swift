import SwiftUI

struct NotchView: View {
    @ObservedObject var model: AnswerModel
    @ObservedObject private var languageStore = AppLanguageStore.shared

    var onHover: (Bool) -> Void
    var onSettings: () -> Void
    var onToggleRecording: () -> Void

    @State private var hovering = false

    private var strings: AppStrings { AppStrings(language: languageStore.language) }

    var body: some View {
        ZStack {
            // A square top edge is intentional: the panel must remain optically fused to
            // the display edge through every intermediate width of the morph.
            NotchShape(bottomRadius: model.expanded ? 19 : 12, topRadius: 0)
                .fill(NotchPalette.background)

            if model.expanded {
                expanded
            } else {
                collapsed
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onHover { inside in
            hovering = inside
            onHover(inside)
        }
    }

    private var statusMark: some View {
        NotchStatusMark(status: model.status,
                        recording: model.recording,
                        activity: model.answer.count / 12)
    }

    private var collapsed: some View {
        HStack(spacing: 5) {
            Button(action: onToggleRecording) {
                HStack(spacing: 5) {
                    statusMark
                    if model.recording {
                        Text("REC")
                            .font(.system(size: 8.5, weight: .bold))
                            .tracking(0.5)
                            .foregroundStyle(NotchPalette.recording)
                    }
                }
                .frame(minWidth: 26, minHeight: 24)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(model.recording ? strings.stopRecording : strings.startRecording)
            .accessibilityLabel(model.recording ? strings.stopRecording : strings.startRecording)
            .accessibilityValue(strings.notchStatus(model.message))
            .padding(.leading, 12)

            Spacer(minLength: 0)

            NotchControlButton(systemName: "gearshape",
                               tint: NotchPalette.secondary,
                               label: strings.settings,
                               action: onSettings)
                .opacity(hovering ? 1 : 0.60)
                .padding(.trailing, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var expanded: some View {
        VStack(spacing: 0) {
            header
            VStack(alignment: .leading, spacing: 7) {
                if !model.question.isEmpty {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(strings.heardLabel)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(NotchPalette.tertiary)
                            .fixedSize()
                        Text(model.question)
                            .font(.system(size: 12, weight: .regular))
                            .foregroundStyle(NotchPalette.secondary)
                            .lineLimit(2)
                            .truncationMode(.tail)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if !model.intentLabel.isEmpty {
                    Text(model.intentLabel)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(NotchPalette.secondary)
                        .lineLimit(1)
                }

                Text(verbatim: displayText)
                    .font(.system(size: model.answer.isEmpty ? 13 : 15, weight: .regular))
                    .tracking(model.answer.isEmpty ? 0 : 0.08)
                    .lineSpacing(model.answer.isEmpty ? 2 : 3)
                    .foregroundStyle(model.answer.isEmpty ? NotchPalette.secondary : NotchPalette.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, model.answer.isEmpty ? 0 : 2)
            .padding(.bottom, 18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var header: some View {
        HStack(spacing: 7) {
            statusMark

            if model.recording {
                Text("REC")
                    .font(.system(size: 8.5, weight: .bold))
                    .tracking(0.5)
                    .foregroundStyle(NotchPalette.recording)
            }

            Text(strings.notchStatus(model.message))
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(NotchPalette.primary)
                .lineLimit(1)

            Spacer(minLength: 120)

            NotchControlButton(systemName: model.recording ? "stop.fill" : "record.circle",
                               tint: model.recording ? NotchPalette.recording : NotchPalette.secondary,
                               label: model.recording ? strings.stopRecording : strings.startRecording,
                               action: onToggleRecording)
            NotchControlButton(systemName: "gearshape",
                               tint: NotchPalette.secondary,
                               label: strings.settings,
                               action: onSettings)
        }
        .padding(.horizontal, 18)
        .padding(.top, 9)
        .padding(.bottom, 8)
    }

    private var displayText: String {
        NotchPresentation.text(answer: model.answer,
                               message: model.message,
                               errorDetail: model.errorDetail,
                               strings: strings)
    }
}
