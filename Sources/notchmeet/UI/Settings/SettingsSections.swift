import AppKit
import SwiftUI

// MARK: - General

struct GeneralSettingsSection: View {
    @ObservedObject private var languageStore = AppLanguageStore.shared

    private var strings: AppStrings { AppStrings(language: languageStore.language) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsPageTitle(title: strings.uiLanguageSettings)
                .padding(.bottom, 18)
            SettingsHairline()

            HStack(alignment: .center, spacing: 20) {
                SettingsSectionHeading(title: strings.uiLanguageSettings,
                                       help: strings.languageSummaryValue)
                Spacer(minLength: 20)
                Picker("", selection: $languageStore.language) {
                    Text(strings.chinese).tag(UILanguage.zh)
                    Text(strings.japanese).tag(UILanguage.ja)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 210)
            }
            .padding(.vertical, 20)

            SettingsHairline()
        }
    }
}

// MARK: - API keys

struct KeysSettingsSection: View {
    let onKeysChanged: () -> Void
    @ObservedObject private var languageStore = AppLanguageStore.shared

    private var strings: AppStrings { AppStrings(language: languageStore.language) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsPageTitle(title: strings.apiKeySettings)
                .padding(.bottom, 18)
            SettingsHairline()

            KeySettingsRow(label: strings.speechRecognitionProvider,
                           name: "DEEPGRAM_API_KEY",
                           onChanged: onKeysChanged)
            SettingsHairline()
            KeySettingsRow(label: "Gemini",
                           name: "GEMINI_API_KEY",
                           onChanged: onKeysChanged)
            SettingsHairline()
            KeySettingsRow(label: "Anthropic (Claude)",
                           name: "ANTHROPIC_API_KEY",
                           onChanged: onKeysChanged)
            SettingsHairline()

            Text(strings.apiKeyPrompt)
                .font(.system(size: 11.5))
                .foregroundStyle(SettingsPalette.tertiary)
                .lineSpacing(2)
                .padding(.top, 14)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct KeySettingsRow: View {
    let label: String
    let name: String
    let onChanged: () -> Void

    @ObservedObject private var languageStore = AppLanguageStore.shared
    @State private var value = ""
    @State private var isSet = false
    @FocusState private var focused: Bool

    private var strings: AppStrings { AppStrings(language: languageStore.language) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: isSet ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(isSet ? SettingsPalette.accent : SettingsPalette.tertiary)
                    .contentTransition(.symbolEffect(.replace))
                Text(label)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(SettingsPalette.primary)
            }

            HStack(spacing: 8) {
                SecureField(strings.apiKeyTitle(label), text: $value)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(SettingsPalette.primary)
                    .focused($focused)
                    .settingsField(focused: focused)
                    .onSubmit(save)

                SettingsButton(title: strings.save, kind: .secondary, minWidth: 40, action: save)
                if isSet {
                    SettingsButton(title: strings.clearKey, kind: .plain, action: clear)
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
            }
        }
        .padding(.vertical, 17)
        .onAppear {
            value = Secrets.get(name) ?? ""
            isSet = !value.isEmpty
        }
        .animation(SettingsPalette.control, value: isSet)
    }

    private func save() {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { Secrets.delete(name) } else { Secrets.set(name, trimmed) }
        isSet = !trimmed.isEmpty
        onChanged()
    }

    private func clear() {
        value = ""
        Secrets.delete(name)
        isSet = false
        onChanged()
    }
}

// MARK: - Answer engine

struct AnswerSettingsSection: View {
    let onBuildBank: () -> Void

    @ObservedObject private var languageStore = AppLanguageStore.shared
    @State private var building = false

    private var strings: AppStrings { AppStrings(language: languageStore.language) }
    private var currentLLM: String {
        if Settings.apiKey("GEMINI_API_KEY") != nil { return "Gemini" }
        if Settings.apiKey("ANTHROPIC_API_KEY") != nil { return "Claude" }
        return strings.notConfigured
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsPageTitle(title: strings.secAnswer)
                .padding(.bottom, 18)
            SettingsHairline()

            HStack(spacing: 20) {
                SettingsSectionHeading(title: strings.currentLLMLabel)
                Spacer()
                HStack(spacing: 7) {
                    Circle()
                        .fill(currentLLM == strings.notConfigured ? SettingsPalette.tertiary : SettingsPalette.accent)
                        .frame(width: 6, height: 6)
                    Text(currentLLM)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(SettingsPalette.primary)
                }
            }
            .padding(.vertical, 19)

            SettingsHairline()

            HStack(spacing: 20) {
                SettingsSectionHeading(title: strings.buildAnswerBank,
                                       help: building ? strings.runtimeMessage(.bankGenerating) : nil)
                Spacer()
                if building {
                    ProgressView().controlSize(.small)
                        .transition(.opacity)
                }
                SettingsButton(title: strings.buildAnswerBank, kind: .secondary) {
                    withAnimation(SettingsPalette.control) { building = true }
                    onBuildBank()
                }
            }
            .padding(.vertical, 19)

            SettingsHairline()
        }
    }
}

// MARK: - Privacy

struct PrivacySettingsSection: View {
    let onDeleteData: () -> Void

    @ObservedObject private var languageStore = AppLanguageStore.shared
    @State private var confirming = false
    @State private var sendContext = Settings.sendContextToLLM
    @State private var targetBundleID: String? = Settings.captureTargetBundleID

    private var strings: AppStrings { AppStrings(language: languageStore.language) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsPageTitle(title: strings.secPrivacy)
                .padding(.bottom, 18)
            SettingsHairline()

            SettingsSectionHeading(title: strings.privacyDataFlowTitle,
                                   help: strings.privacyDataFlowBody)
                .padding(.vertical, 25.5)

            SettingsHairline()

            HStack(alignment: .top, spacing: 18) {
                SettingsSectionHeading(title: strings.sendContextLabel,
                                       help: strings.sendContextHelp)
                Spacer(minLength: 16)
                Toggle("", isOn: Binding(
                    get: { sendContext },
                    set: { sendContext = $0; Settings.sendContextToLLM = $0 }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .padding(.top, 1)
            }
            .padding(.vertical, 17)

            SettingsHairline()

            VStack(alignment: .leading, spacing: 10) {
                SettingsSectionHeading(title: strings.captureTargetLabel)
                Picker("", selection: Binding(
                    get: { targetBundleID ?? "" },
                    set: {
                        targetBundleID = $0.isEmpty ? nil : $0
                        Settings.captureTargetBundleID = targetBundleID
                    }
                )) {
                    Text(strings.captureTargetAuto).tag("")
                    ForEach(appOptions(), id: \.id) { option in
                        Text(option.name).tag(option.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: 300, alignment: .leading)

                Text(strings.captureTargetHelp)
                    .font(.system(size: 11.5))
                    .foregroundStyle(SettingsPalette.secondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 21.5)

            SettingsHairline()

            HStack(alignment: .center, spacing: 20) {
                Text(strings.deleteConfirmBody)
                    .font(.system(size: 11.5))
                    .foregroundStyle(SettingsPalette.secondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 12)
                SettingsButton(title: strings.deleteLocalData, kind: .destructive) {
                    confirming = true
                }
            }
            .padding(.vertical, 22.5)
        }
        .alert(strings.deleteConfirmTitle, isPresented: $confirming) {
            Button(strings.deleteButton, role: .destructive) { onDeleteData() }
            Button(strings.cancel, role: .cancel) {}
        } message: {
            Text(strings.deleteConfirmBody)
        }
    }

    private func appOptions() -> [(id: String, name: String)] {
        var pairs: [(String, String)] = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil }
            .map { ($0.bundleIdentifier!, $0.localizedName ?? $0.bundleIdentifier!) }
        if let selected = targetBundleID, !pairs.contains(where: { $0.0 == selected }) {
            pairs.append((selected, selected))
        }
        var seen = Set<String>()
        return pairs
            .filter { seen.insert($0.0).inserted }
            .sorted { $0.1.localizedCaseInsensitiveCompare($1.1) == .orderedAscending }
            .map { (id: $0.0, name: $0.1) }
    }
}

// MARK: - About

struct AboutSettingsSection: View {
    let onRerunOnboarding: () -> Void

    @ObservedObject private var languageStore = AppLanguageStore.shared

    private var strings: AppStrings { AppStrings(language: languageStore.language) }
    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsPageTitle(title: strings.notchTitle)
                .padding(.bottom, 14)
            Text(strings.aboutTagline)
                .font(.system(size: 13))
                .foregroundStyle(SettingsPalette.secondary)
                .padding(.bottom, 24)
            SettingsHairline()

            HStack {
                SettingsSectionHeading(title: strings.aboutVersion)
                Spacer()
                Text(version)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(SettingsPalette.primary)
            }
            .padding(.vertical, 19)

            SettingsHairline()

            HStack {
                SettingsSectionHeading(title: strings.rerunOnboarding)
                Spacer()
                SettingsButton(title: strings.rerunOnboarding, kind: .secondary,
                               action: onRerunOnboarding)
            }
            .padding(.vertical, 19)

            SettingsHairline()
        }
    }
}
