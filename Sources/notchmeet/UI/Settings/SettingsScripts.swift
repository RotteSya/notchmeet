import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ScriptsSettingsSection: View {
    @ObservedObject var store: ScriptStore
    @ObservedObject private var languageStore = AppLanguageStore.shared

    @State private var editing: EditTarget?
    @State private var renamingID: String?
    @State private var renameText = ""
    @State private var pendingDelete: InterviewScript?

    private var strings: AppStrings { AppStrings(language: languageStore.language) }

    enum EditTarget: Identifiable {
        case new(name: String, text: String)
        case existing(id: String)

        var id: String {
            switch self {
            case .new: "new"
            case .existing(let id): id
            }
        }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let editing {
                editor(editing)
                    .transition(.opacity.combined(with: .offset(x: 8)))
            } else {
                list
                    .transition(.opacity.combined(with: .offset(x: -6)))
            }
        }
        .animation(SettingsPalette.navigation, value: editing?.id)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center, spacing: 8) {
                    SettingsPageTitle(title: strings.secScripts)
                    Spacer()
                    SettingsButton(title: strings.addByFile,
                                   systemImage: "square.and.arrow.down",
                                   kind: .secondary,
                                   action: importFromFile)
                    SettingsButton(title: strings.addByPaste,
                                   systemImage: "doc.badge.plus",
                                   kind: .primary) {
                        editing = .new(name: "", text: "")
                    }
                }
                .padding(.bottom, 18)

                SettingsHairline()

                if store.all.isEmpty {
                    emptyState
                } else {
                    ForEach(store.all) { script in
                        ScriptSettingsRow(
                            script: script,
                            active: store.activeID == script.id,
                            renaming: renamingID == script.id,
                            renameText: $renameText,
                            strings: strings,
                            dateText: dateString(script.updatedAt),
                            onSetActive: { store.setActive(script.id) },
                            onEdit: { editing = .existing(id: script.id) },
                            onRename: {
                                renamingID = script.id
                                renameText = script.name
                            },
                            onCommitRename: { commitRename(script) },
                            onDelete: { pendingDelete = script }
                        )
                        SettingsHairline()
                    }
                }
            }
            .padding(.horizontal, 30)
            .padding(.top, 26)
            .padding(.bottom, 30)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .alert(
            pendingDelete.map { strings.deleteScriptConfirmTitle($0.name) } ?? "",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            presenting: pendingDelete
        ) { script in
            Button(strings.deleteButton, role: .destructive) {
                store.remove(id: script.id)
                pendingDelete = nil
            }
            Button(strings.cancel, role: .cancel) { pendingDelete = nil }
        } message: { _ in
            Text(strings.deleteScriptConfirmBody)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "doc.text")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(SettingsPalette.tertiary)
                .padding(.bottom, 3)
            Text(strings.scriptsEmptyTitle)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(SettingsPalette.primary)
            Text(strings.scriptsEmptyHint)
                .font(.system(size: 12))
                .foregroundStyle(SettingsPalette.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .frame(maxWidth: 430)
        }
        .frame(maxWidth: .infinity, minHeight: 230, alignment: .center)
    }

    @ViewBuilder private func editor(_ target: EditTarget) -> some View {
        switch target {
        case .new(let name, let text):
            ScriptSettingsEditor(
                title: strings.newScriptTitle,
                name: name,
                text: text,
                onCancel: { editing = nil },
                onSave: { newName, entries in
                    store.add(name: resolvedName(newName, entries: entries), entries: entries)
                    editing = nil
                }
            )
        case .existing(let id):
            let script = store.all.first { $0.id == id }
            ScriptSettingsEditor(
                title: script?.name ?? strings.editScript,
                name: script?.name ?? "",
                text: store.conventionText(for: id),
                onCancel: { editing = nil },
                onSave: { newName, entries in
                    store.update(id: id, name: newName, entries: entries)
                    editing = nil
                }
            )
        }
    }

    private func commitRename(_ script: InterviewScript) {
        store.update(id: script.id, name: renameText)
        renamingID = nil
    }

    private func resolvedName(_ typed: String, entries: [BankEntry]) -> String {
        let name = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? (entries.first?.question ?? "") : name
    }

    private func importFromFile() {
        let panel = NSOpenPanel()
        var types: [UTType] = [.plainText, .text]
        if let markdown = UTType(filenameExtension: "md") { types.append(markdown) }
        if let markdown = UTType(filenameExtension: "markdown") { types.append(markdown) }
        panel.allowedContentTypes = types
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        if panel.runModal() == .OK,
           let url = panel.url,
           let content = try? String(contentsOf: url, encoding: .utf8) {
            editing = .new(name: url.deletingPathExtension().lastPathComponent, text: content)
        }
    }

    private func dateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        formatter.locale = Locale(identifier: languageStore.language == .zh ? "zh_CN" : "ja_JP")
        return formatter.string(from: date)
    }
}

private struct ScriptSettingsRow: View {
    let script: InterviewScript
    let active: Bool
    let renaming: Bool
    @Binding var renameText: String
    let strings: AppStrings
    let dateText: String
    let onSetActive: () -> Void
    let onEdit: () -> Void
    let onRename: () -> Void
    let onCommitRename: () -> Void
    let onDelete: () -> Void

    @State private var hovering = false
    @FocusState private var renameFocused: Bool

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                if renaming {
                    TextField(strings.scriptNamePlaceholder, text: $renameText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(SettingsPalette.primary)
                        .focused($renameFocused)
                        .settingsField(focused: renameFocused)
                        .frame(maxWidth: 250)
                        .onSubmit(onCommitRename)
                        .onAppear { renameFocused = true }
                } else {
                    HStack(spacing: 8) {
                        Text(script.name)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(SettingsPalette.primary)
                        if active {
                            Text(strings.activeBadge)
                                .font(.system(size: 9.5, weight: .semibold))
                                .foregroundStyle(SettingsPalette.accent)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(SettingsPalette.accent.opacity(0.12))
                                .clipShape(Capsule())
                        }
                    }
                }

                Text("\(strings.scriptCount(script.entries.count)) · \(strings.scriptUpdated(dateText))")
                    .font(.system(size: 11))
                    .foregroundStyle(SettingsPalette.tertiary)
            }

            Spacer(minLength: 10)

            HStack(spacing: 2) {
                if !active {
                    SettingsButton(title: strings.setActiveScript, kind: .plain, action: onSetActive)
                }
                SettingsButton(title: strings.editScript, systemImage: "pencil", kind: .plain, action: onEdit)
                SettingsButton(title: strings.renameScript, kind: .plain, action: onRename)
                SettingsButton(title: strings.deleteButton,
                               systemImage: "trash",
                               kind: .plain,
                               tint: SettingsPalette.destructive,
                               action: onDelete)
            }
            .opacity(hovering || renaming ? 1 : 0.72)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 14)
        .background(hovering ? SettingsPalette.selectionHover : .clear)
        .contentShape(Rectangle())
        .onHover { value in withAnimation(SettingsPalette.control) { hovering = value } }
    }
}

private struct ScriptSettingsEditor: View {
    @ObservedObject private var languageStore = AppLanguageStore.shared
    @State private var name: String
    @State private var text: String
    @FocusState private var nameFocused: Bool

    let title: String
    let onCancel: () -> Void
    let onSave: (_ name: String, _ entries: [BankEntry]) -> Void

    init(title: String,
         name: String,
         text: String,
         onCancel: @escaping () -> Void,
         onSave: @escaping (String, [BankEntry]) -> Void) {
        self.title = title
        _name = State(initialValue: name)
        _text = State(initialValue: text)
        self.onCancel = onCancel
        self.onSave = onSave
    }

    private var strings: AppStrings { AppStrings(language: languageStore.language) }
    private var parsed: [BankEntry] { ScriptParser.parse(text) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                SettingsButton(title: strings.back,
                               systemImage: "chevron.left",
                               kind: .plain,
                               action: onCancel)
                SettingsPageTitle(title: title)
                Spacer()
                SettingsButton(title: strings.saveWithShortcut, kind: .primary) {
                    onSave(name, parsed)
                }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(parsed.isEmpty)
            }
            .padding(.bottom, 20)

            SettingsHairline()

            TextField(strings.scriptNamePlaceholder, text: $name)
                .textFieldStyle(.plain)
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(SettingsPalette.primary)
                .focused($nameFocused)
                .settingsField(focused: nameFocused)
                .padding(.top, 16)

            Text(strings.prepDescription)
                .font(.system(size: 11.5))
                .foregroundStyle(SettingsPalette.secondary)
                .lineSpacing(2)
                .padding(.top, 10)

            Text(previewLine)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(parsed.isEmpty ? SettingsPalette.tertiary : SettingsPalette.accent)
                .lineLimit(2)
                .padding(.vertical, 10)

            TextEditor(text: $text)
                .font(.system(size: 12.5, design: .monospaced))
                .foregroundStyle(SettingsPalette.primary)
                .scrollContentBackground(.hidden)
                .padding(9)
                .background(SettingsPalette.field)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(SettingsPalette.fieldBorder, lineWidth: SettingsPalette.hairline)
                )
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .frame(minHeight: 220, maxHeight: .infinity)
        }
        .padding(.horizontal, 30)
        .padding(.top, 24)
        .padding(.bottom, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var previewLine: String {
        let names = parsed.prefix(6).map(\.question).joined(separator: " / ")
        return strings.prepRecognition(count: parsed.count, names: names, hasMore: parsed.count > 6)
    }
}
