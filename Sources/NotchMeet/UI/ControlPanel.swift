import AppKit

/// The notch's right-side button menu. Pared down to in-the-moment controls only:
/// pre-interview self-check, start/stop recording, the active-script PICKER for this
/// interview, show/hide, and an entry into the full settings window. Everything
/// configuration-y (language, API keys, script management, prebuild, data wipe) now lives
/// in `SettingsWindowController`.
final class ControlPanel: NSObject {
    private let menu = NSMenu()

    /// Pre-interview self-check snapshot (PLAN §3 S1 readiness).
    struct Health {
        var recording = false
        var captureOK = false
        var captureState: CaptureHealthState = .notStarted
        var sttConnected = false
        var deepgramKey = false
        var llm: String?
        /// 国内网络 + 解析结果是被墙端点（Gemini/Claude）：LLM 行降级为 ⚠️ 并附提示。
        var llmChinaBlocked = false
        var screenShareGuard = false
        static let empty = Health()
    }

    var onToggleRecording: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onManageScripts: (() -> Void)?
    /// Pick the script used for this interview (nil = none). Applied to the shared store.
    var onSelectScript: ((String?) -> Void)?
    var onMenuVisibilityChanged: ((Bool) -> Void)?
    /// Queried each time the menu opens, so the self-check reflects live state.
    var healthProvider: (() -> Health)?
    /// Source of truth lives in AppController; read on each rebuild for the menu label.
    var recordingProvider: (() -> Bool)?
    /// All imported scripts + which one is active — read on each rebuild for the picker.
    var scriptsProvider: (() -> (scripts: [InterviewScript], activeID: String?))?

    func install() {
        menu.delegate = self
        rebuild()
    }

    func showMenu(at screenPoint: NSPoint) {
        rebuild()
        menu.popUp(positioning: nil, at: screenPoint, in: nil)
    }

    func toggleRecording() {
        onToggleRecording?()
        rebuild()
    }

    func refreshLocalization() { rebuild() }

    private func rebuild() {
        menu.removeAllItems()
        let t = AppStrings.current

        // Pre-interview self-check — glance before the call to confirm state. The audio/STT
        // rows only carry a ✓/✗ while recording; idle shows "・" so "not started" never reads
        // as "broken".
        if let h = healthProvider?() {
            addInfo(menu, t.selfCheck)
            addInfo(menu, "   \(h.recording ? t.recordingStatusOn : t.recordingStatusOff)")
            let audioMark = h.recording ? (h.captureOK ? "✓" : "✗") : "・"
            let sttMark = h.recording ? (h.sttConnected ? "✓" : "✗") : "・"
            addInfo(menu, "   \(t.interviewerAudio)  \(audioMark)  \(t.captureHealth(h.captureState))")
            addInfo(menu, "   \(t.sttConnection)  \(sttMark)")
            addInfo(menu, "   \(t.deepgramKey)  \(h.deepgramKey ? "✓" : "✗")")
            // 配了 Key 但端点在当前网络被墙 → 不能亮 ✓（会假装就绪），降级为 ⚠️ + 修复提示。
            let llmStatus: String = if let name = h.llm {
                h.llmChinaBlocked ? "⚠️ \(name)" : "✓ \(name)"
            } else {
                "✗ \(t.notConfigured)"
            }
            addInfo(menu, "   \(t.answerLLM)  \(llmStatus)")
            if h.llm != nil, h.llmChinaBlocked {
                addInfo(menu, "      \(t.llmChinaBlockedWarning)")
            }
            addInfo(menu, "   \(t.screenShareGuard)  \(h.screenShareGuard ? "✓" : "⚠️")")
            menu.addItem(.separator())
        }

        let isRecording = recordingProvider?() ?? false
        add(menu, isRecording ? t.stopRecording : t.startRecording, #selector(recordTapped))

        // Active-script picker for THIS interview (management lives in the settings window).
        let scriptItem = NSMenuItem(title: t.thisInterviewScript, action: nil, keyEquivalent: "")
        scriptItem.submenu = buildScriptMenu(t)
        menu.addItem(scriptItem)
        menu.addItem(.separator())

        add(menu, t.openSettings, #selector(openSettingsTapped))
        add(menu, t.toggleVisibility, #selector(noop))
        menu.addItem(.separator())
        add(menu, t.quit, #selector(quit))
    }

    private func buildScriptMenu(_ t: AppStrings) -> NSMenu {
        let sub = NSMenu()
        let data = scriptsProvider?() ?? (scripts: [], activeID: nil)
        for s in data.scripts {
            let on = s.id == data.activeID
            let item = NSMenuItem(title: "\(on ? "✓ " : "")\(s.name)（\(t.scriptCount(s.entries.count))）",
                                  action: #selector(scriptTapped(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = s.id
            sub.addItem(item)
        }
        if !data.scripts.isEmpty { sub.addItem(.separator()) }
        let none = NSMenuItem(title: "\(data.activeID == nil ? "✓ " : "")\(t.scriptNone)",
                              action: #selector(scriptNoneTapped), keyEquivalent: "")
        none.target = self
        sub.addItem(none)
        sub.addItem(.separator())
        add(sub, t.manageScripts, #selector(manageScriptsTapped))
        return sub
    }

    private func add(_ menu: NSMenu, _ title: String, _ action: Selector) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    /// Non-actionable info row (shown disabled/grayed) for the self-check section.
    private func addInfo(_ menu: NSMenu, _ title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    @objc private func recordTapped() { toggleRecording() }
    @objc private func openSettingsTapped() { onOpenSettings?() }
    @objc private func manageScriptsTapped() { onManageScripts?() }
    @objc private func scriptTapped(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        onSelectScript?(id)
    }
    @objc private func scriptNoneTapped() { onSelectScript?(nil) }
    @objc private func noop() {}
    @objc private func quit() { NSApp.terminate(nil) }
}

extension ControlPanel: NSMenuDelegate {
    /// Repopulate just before the menu shows, so the self-check + picker reflect current state.
    func menuNeedsUpdate(_ menu: NSMenu) { rebuild() }
    func menuWillOpen(_ menu: NSMenu) { onMenuVisibilityChanged?(true) }
    func menuDidClose(_ menu: NSMenu) { onMenuVisibilityChanged?(false) }
}
