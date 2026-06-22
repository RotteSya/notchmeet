import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: ScriptStore
    @ObservedObject var nav: SettingsNav
    @ObservedObject private var languageStore = AppLanguageStore.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let onKeysChanged: () -> Void
    let onBuildBank: () -> Void
    let onDeleteData: () -> Void
    let onRerunOnboarding: () -> Void

    private var strings: AppStrings { AppStrings(language: languageStore.language) }

    var body: some View {
        VStack(spacing: 0) {
            titlebar
            SettingsHairline()
            HStack(spacing: 0) {
                SettingsSidebar(nav: nav, strings: strings)
                    .frame(width: 170)
                SettingsHairline(vertical: true)
                detail
            }
        }
        .frame(minWidth: 720, minHeight: 520)
        .background(SettingsPalette.window)
        .environment(\.colorScheme, .dark)
        .ignoresSafeArea(.container, edges: .top)
    }

    private var titlebar: some View {
        ZStack {
            SettingsPalette.titlebar
            Text("NotchMeet  \(strings.settings)")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(SettingsPalette.secondary)
                .allowsHitTesting(false)
        }
        .frame(height: 40)
    }

    @ViewBuilder private var detailContent: some View {
        switch nav.section {
        case .general:
            SettingsScroll { GeneralSettingsSection() }
        case .scripts:
            ScriptsSettingsSection(store: store)
        case .keys:
            SettingsScroll { KeysSettingsSection(onKeysChanged: onKeysChanged) }
        case .answer:
            SettingsScroll { AnswerSettingsSection(onBuildBank: onBuildBank) }
        case .privacy:
            SettingsScroll { PrivacySettingsSection(onDeleteData: onDeleteData) }
        case .about:
            SettingsScroll { AboutSettingsSection(onRerunOnboarding: onRerunOnboarding) }
        }
    }

    private var detail: some View {
        ZStack(alignment: .topLeading) {
            SettingsPalette.content
            detailContent
                .id(nav.section)
                .transition(reduceMotion ? .opacity : .asymmetric(
                    insertion: .opacity.combined(with: .offset(x: 6)),
                    removal: .opacity.combined(with: .offset(x: -4))
                ))
        }
        .clipped()
        .animation(reduceMotion ? nil : SettingsPalette.navigation, value: nav.section)
    }
}

private struct SettingsSidebar: View {
    @ObservedObject var nav: SettingsNav
    let strings: AppStrings

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(strings.settings)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(SettingsPalette.tertiary)
                .padding(.horizontal, 18)
                .padding(.top, 28)
                .padding(.bottom, 10)

            ForEach(SettingsSection.allCases) { section in
                SettingsSidebarRow(section: section,
                                   title: section.title(strings),
                                   selected: nav.section == section) {
                    withAnimation(SettingsPalette.navigation) { nav.section = section }
                }
            }
            Spacer(minLength: 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(SettingsPalette.sidebar)
    }
}

private struct SettingsSidebarRow: View {
    let section: SettingsSection
    let title: String
    let selected: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: section.icon)
                    .font(.system(size: 12.5, weight: selected ? .semibold : .regular))
                    .frame(width: 16)
                Text(title)
                    .font(.system(size: 13, weight: selected ? .medium : .regular))
                Spacer(minLength: 0)
            }
            .foregroundStyle(selected ? SettingsPalette.primary : SettingsPalette.secondary)
            .padding(.horizontal, 11)
            .frame(height: 32)
            .background(selected ? SettingsPalette.selection : (hovering ? SettingsPalette.selectionHover : .clear))
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 9)
        .onHover { value in withAnimation(SettingsPalette.control) { hovering = value } }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct SettingsScroll<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ScrollView {
            content
                .padding(.horizontal, 30)
                .padding(.top, 26)
                .padding(.bottom, 30)
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.automatic)
    }
}
