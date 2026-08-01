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
        /// 本场选用的稿件（含公司名）。nil = 一份都没选。
        var activeScript: String?
        /// 库里有稿但一份都没选 —— 静默地整场不命中，必须标出来。
        var hasScriptsButNoneActive = false
        /// 剩余额度秒数；nil = 本机全 BYO/本地（额度概念不适用，菜单不显示）。
        var creditSeconds: Int?
        static let empty = Health()
    }

    var onToggleRecording: (() -> Void)?
    /// 回看上一条已显示过的回答 / 回到当前。被追问打断时上一条不再永久丢失。
    var onReviewPrevious: (() -> Void)?
    var onReviewReturnLive: (() -> Void)?
    /// 当前是否有更早的回答可看、是否正在回看——菜单据此显示，不给死按钮。
    var reviewStateProvider: (() -> (canStepBack: Bool, isReviewing: Bool))?
    /// 显示/隐藏刘海。此前这一项挂在空实现上：菜单可点、毫无反应，
    /// 真正的实现只绑在热键（⌘⇧H）上。
    var onToggleVisibility: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onOpenWallet: (() -> Void)?
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
            // 本场用稿：拿 A 公司的稿进 B 公司面试是最致命的静默失败，
            // 而此前一级菜单里根本看不到当前用的是哪一份（只藏在二级子菜单）。
            if let script = h.activeScript {
                addInfo(menu, "   \(t.thisInterviewScript)  ✓ \(script)")
            } else {
                addInfo(menu, "   \(t.thisInterviewScript)  \(h.hasScriptsButNoneActive ? "⚠️" : "・")  \(t.scriptNone)")
            }
            // 额度行：受管服务的用户一眼看到还能面多久；<10 分钟标 ⚠️ 提醒面前充值。
            if let credit = h.creditSeconds {
                let mark = credit <= 0 ? "✗" : (credit <= 600 ? "⚠️" : "✓")
                addInfo(menu, "   \(t.creditRemainingLabel)  \(mark) \(t.creditMinutes(credit))")
            }
            menu.addItem(.separator())
        }

        let isRecording = recordingProvider?() ?? false
        add(menu, isRecording ? t.stopRecording : t.startRecording, #selector(recordTapped))

        // 回看：热键 ⌘⇧B 是面试中真正会用的入口（菜单要动鼠标、还会多亮一块 UI），
        // 这两项只为可发现性存在，没有可看的东西时置灰而不是给一个没反应的按钮。
        let review = reviewStateProvider?() ?? (canStepBack: false, isReviewing: false)
        if review.canStepBack || review.isReviewing {
            if review.canStepBack {
                add(menu, "\(t.reviewPrevious)  ⌘⇧B", #selector(reviewPreviousTapped))
            }
            if review.isReviewing {
                add(menu, t.reviewReturnLive, #selector(reviewReturnLiveTapped))
            }
        }

        // Active-script picker for THIS interview (management lives in the settings window).
        let scriptItem = NSMenuItem(title: t.thisInterviewScript, action: nil, keyEquivalent: "")
        scriptItem.submenu = buildScriptMenu(t)
        menu.addItem(scriptItem)
        menu.addItem(.separator())

        add(menu, t.openSettings, #selector(openSettingsTapped))
        add(menu, t.creditMenuTopUp, #selector(openWalletTapped))
        add(menu, t.toggleVisibility, #selector(toggleVisibilityTapped))
        menu.addItem(.separator())
        add(menu, t.quit, #selector(quit))
    }

    private func buildScriptMenu(_ t: AppStrings) -> NSMenu {
        let sub = NSMenu()
        // 子菜单是悬停时才创建的**另一个**窗口，父菜单的排除不覆盖它——而这一屏正是公司名。
        ScreenShareGuard.protect(sub)
        let data = scriptsProvider?() ?? (scripts: [], activeID: nil)
        for s in data.scripts {
            let on = s.id == data.activeID
            let item = NSMenuItem(title: "\(on ? "✓ " : "")\(s.displayLabel) · \(t.scriptCount(s.entries.count))",
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
    @objc private func reviewPreviousTapped() { onReviewPrevious?() }
    @objc private func reviewReturnLiveTapped() { onReviewReturnLive?() }
    @objc private func openSettingsTapped() { onOpenSettings?() }
    @objc private func openWalletTapped() { onOpenWallet?() }
    @objc private func manageScriptsTapped() { onManageScripts?() }
    @objc private func scriptTapped(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        onSelectScript?(id)
    }
    @objc private func scriptNoneTapped() { onSelectScript?(nil) }
    @objc private func toggleVisibilityTapped() { onToggleVisibility?() }
    @objc private func quit() { NSApp.terminate(nil) }
}

extension ControlPanel: NSMenuDelegate {
    /// Repopulate just before the menu shows, so the self-check + picker reflect current state.
    func menuNeedsUpdate(_ menu: NSMenu) { rebuild() }
    func menuWillOpen(_ menu: NSMenu) {
        // 菜单窗口此刻已创建、尚未上屏 —— 这是把它挡在屏幕共享之外的唯一零帧时机。
        // 这个菜单里有自检状态和原稿名（公司名），面试官看到就是灾难。
        ScreenShareGuard.excludeMenuWindowsNow()
        onMenuVisibilityChanged?(true)
    }
    func menuDidClose(_ menu: NSMenu) { onMenuVisibilityChanged?(false) }
}
