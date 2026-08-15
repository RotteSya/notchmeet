import AppKit
import Carbon.HIToolbox
import Combine

/// Top-level wiring. Owns the notch UI + the live pipeline + the control surface.
final class AppController {
    let notch = NotchController()
    private var stt: SttClient?
    private var turn: TurnManager?
    private var audio: AudioCapture?
    private let facts = FactStore()
    private let bank = AnswerBank()
    private let scriptStore = ScriptStore()
    private let targetStore = TargetStore()
    private let portrait = PortraitIndex()
    private let control = ControlPanel()
    private let inactivity = InactivityMonitor()
    /// 本场已显示过的回答（全文，仅内存）。被追问打断时用 ⌘⇧B 回看上一条。
    private lazy var answerHistory = AnswerHistory(model: notch.model)
    /// 面试复盘记录（仅本机、可关、进「删除本地数据」）。
    private let sessions = SessionStore()
    private var settingsWindow: SettingsWindowController?
    private var workbench: WorkbenchWindowController?
    private var onboarding: OnboardingWindowController?
    /// 引导导入步读到的简历：引导结束后移交工作台走完整解析确认流。
    private var pendingOnboardingResume: URL?
    private let demoVoice = DemoVoice()
    private var demoUnpauseWork: DispatchWorkItem?
    private var captureStarted = false   // tap.start() succeeded & running (self-check)
    /// 「正在录音」这一个事实此前由四份状态分别维护（本字段、`notch.model.recording`、
    /// `CreditManager.meteringActive`、反相语义的 `TurnManager.paused`），由五条
    /// teardown 路径手工同步。漏一处的表现不是崩溃而是静默错账——F1 的静默扣费就是
    /// 这么来的。现在统一经由 `setRecording(_:)` 变更，新增停止路径不可能再漏。
    private(set) var recording = false   // explicit session is live (tap + STT uploading)

    /// 录音状态的**唯一**写入口：一次调用把派生状态全部对齐。
    private func setRecording(_ on: Bool) {
        recording = on
        notch.model.recording = on
        turn?.paused = !on   // 停止时丢弃在途转录，避免停后还弹出答案
    }
    /// 转写断连/重连期间刘海显示的裁决（审计 R4/R5，纯状态机可测）。
    private var sttOutage = SttOutageUIState()
    /// 慢终稿探测（审计 R1）：连续超阈值 → 面试中热切换到端侧引擎。
    private var sttHealth = SttHealthTracker()
    /// 本场是否已尝试过热切换（成败都算）。切换是一次性止损，不反复横跳。
    private var sttDegradedThisSession = false
    /// 管线装配那一刻的面试语言快照。STT/路由/TurnManager 的语言全部以它为源——
    /// 待机期间用户改了设置，由 `startRecording` 兑现「下一次开始录音时生效」的承诺
    /// （重建管线）；录音中改设置对本场无效（含 R1 热切换，见 `degradeSttToApple`）。
    private var armedInterviewLanguage: InterviewLanguage = .japanese
    private var sttSwitchRevertWork: DispatchWorkItem?
    private var languageCancellable: AnyCancellable?
    private var portraitCancellable: AnyCancellable?
    private let credit = CreditManager.shared
    private var creditCancellables = Set<AnyCancellable>()
    private var creditLowRevertWork: DispatchWorkItem?
    private var connectionKeepWarm: Timer?

    func start() {
        Settings.cleanupLegacyKeys()
        bootstrapCreditIfAllowed()
        // 菜单窗口是 AppKit 私有窗口，只能在它出现的那一刻补设 sharingType——在任何 UI
        // 之前装好这道闸门（PLAN §3 S4）。窗口总兜底同理：TUINSWindow（输入候选）、
        // tooltip 等 AppKit 自建窗口没有构造点，只能在首次绘制时补设。
        ScreenShareGuard.installMenuGuard()
        ScreenShareGuard.installWindowGuard()
        notch.show()
        installEditMenu()
        installControls()
        observeLanguageChanges()
        observePortraitSources()
        // 目标维度的首启播种：从存量稿件公司与志望公司生成目标。只在 targets.json
        // 尚不存在时发生；产出为零不落盘，下次启动无害重试。
        targetStore.seedIfNeeded(scripts: scriptStore.all,
                                 activeScriptID: scriptStore.activeID,
                                 motivations: facts.sheet.motivations)
        // 上次武装的目标持久有效：启动即整条兑现（答案库 + 绑定用稿 + 画像 + 热词）。
        // 只 activate 答案库不够——目标绑的稿与 scriptStore.activeID 可能早已分叉
        // （旧版本、或任何只改一半的路径留下的状态），那会让「本场用稿」显示 A 家、
        // 实际读 B 家的稿。启动对齐是这个不一致的兜底自愈点。
        applyTarget(targetStore.activeID)
        if ProcessInfo.processInfo.environment["FI_PREP"] == "1" { runPrep() }
        reloadPipeline()
        // Dev-only visual-QA hook: open settings straight to a section so the redesign can be
        // screenshotted (FI_OPEN_SETTINGS=privacy, or `--open-settings privacy`). Never fires
        // without the env var / launch arg.
        let args = ProcessInfo.processInfo.arguments
        let argSection = args.firstIndex(of: "--open-settings").flatMap { i in
            args.indices.contains(i + 1) ? args[i + 1] : nil
        }
        if let raw = ProcessInfo.processInfo.environment["FI_OPEN_SETTINGS"] ?? argSection {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.openSettings(section: SettingsSection(rawValue: raw))
            }
        } else if ProcessInfo.processInfo.environment["FI_OPEN_WORKBENCH"] == "1"
                    || args.contains("--open-workbench") {
            // 视觉 QA：直接打开备战工作台。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.openWorkbench()
            }
            #if DEBUG
            // 视觉 QA：FI_QA_FLYIN=1 自动触发「准备面试」（配 FI_SLOW_FLYIN=1 逐帧检查）。
            if ProcessInfo.processInfo.environment["FI_QA_FLYIN"] == "1" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
                    guard let self, let target = self.targetStore.active else { return }
                    self.prepareForInterview(target)
                }
            }
            #endif
        } else if ProcessInfo.processInfo.environment["FI_OPEN_ONBOARDING"] == "1" {
            // 视觉 QA：不改动真实的 nm_onboarded 状态，直接打开引导流程。
            openOnboarding()
        } else if !Settings.onboarded {
            openOnboarding()
        }
    }

    /// 启动期的计费初始化——start() 里**唯一**允许碰 Keychain 的路径。
    ///
    /// demo 管线（FI_UI_DEMO 视觉 QA，承诺零 Keychain 访问）下整体跳过，缺一不可：
    /// 迁移会把「已迁移」标记落进 UserDefaults（真实启动从此不再迁移，存量用户的
    /// 受管标记永久丢失），bootstrap 会把迎新赠礼记进 RedemptionJournal（真实启动
    /// 从此不再发放）——在 demo 的丢弃式内存账本上跑一遍，等于把这两样烧掉。
    private func bootstrapCreditIfAllowed() {
        guard AppConfig.keychainAllowed else { return }
        // 受管标记 UserDefaults → Keychain 指纹的一次性迁移。必须在 bootstrap 之前：
        // 之后的一切计费判定（CreditPolicy）都依赖指纹登记。
        ManagedKeyRegistry.migrateLegacyFlagsIfNeeded()
        credit.bootstrap()               // 迎新赠礼（仅出厂带受管服务的构建）
        observeCredit()
    }

    /// A menu-bar-only app has no Edit menu, so ⌘X/⌘C/⌘V key-equivalents aren't
    /// routed to focused text fields. Install a minimal one so paste works.
    private func installEditMenu() {
        let t = AppStrings.current
        let main = NSMenu()
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: t.editMenu)
        ScreenShareGuard.protect(edit)   // accessory 下菜单栏不显示，但键盘等价键仍会路由到它
        editItem.submenu = edit
        edit.addItem(withTitle: t.cut, action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: t.copy, action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: t.paste, action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: t.selectAll, action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        NSApp.mainMenu = main
    }

    private func observeLanguageChanges() {
        languageCancellable = AppLanguageStore.shared.$language
            .dropFirst()
            .sink { [weak self] _ in
                self?.installEditMenu()
                self?.control.refreshLocalization()
            }
    }

    /// 设置窗共享 live `scriptStore`：改条目/换稿下一轮就要生效，画像必须跟着重建。
    /// 开录快照会再编一次（待机期间改了简历、还没 reloadPipeline 的路径）。
    private func observePortraitSources() {
        portraitCancellable = scriptStore.$library
            .sink { [weak self] _ in self?.rebuildPortrait() }
    }

    private func rebuildPortrait() {
        let lang = recording ? armedInterviewLanguage : Settings.interviewLanguage
        portrait.rebuild(sheet: facts.sheet, script: scriptStore.active,
                         target: targetStore.active, language: lang)
    }

    private func installControls() {
        control.install()
        notch.onSettings = { [weak self] point in self?.control.showMenu(at: point) }
        notch.onToggleRecording = { [weak self] in self?.toggleRecording() }
        notch.onPromptAction = { [weak self] action in self?.handleNotchPromptAction(action) }
        control.onMenuVisibilityChanged = { [weak self] open in self?.notch.setSettingsMenuOpen(open) }
        control.onToggleRecording = { [weak self] in self?.toggleRecording() }
        control.recordingProvider = { [weak self] in self?.recording ?? false }
        control.scriptsProvider = { [weak self] in (self?.scriptStore.all ?? [], self?.scriptStore.activeID) }
        control.onSelectScript = { [weak self] id in self?.scriptStore.setActive(id) }
        control.targetsProvider = { [weak self] in (self?.targetStore.all ?? [], self?.targetStore.activeID) }
        control.onSelectTarget = { [weak self] id in self?.applyTarget(id) }
        control.onManageTargets = { [weak self] in self?.openWorkbench() }
        control.onOpenSettings = { [weak self] in self?.openSettings() }
        control.onOpenWorkbench = { [weak self] in self?.openWorkbench() }
        control.onOpenWallet = { [weak self] in self?.openSettings(section: .wallet) }
        control.onManageScripts = { [weak self] in self?.openSettings(section: .scripts) }
        control.healthProvider = { [weak self] in self?.currentHealth() ?? .empty }
        control.onToggleVisibility = { [weak self] in self?.notch.toggleVisibility() }
        control.onReviewPrevious = { [weak self] in self?.answerHistory.stepBack() }
        control.onReviewReturnLive = { [weak self] in self?.answerHistory.returnToLive() }
        control.reviewStateProvider = { [weak self] in
            guard let self else { return (canStepBack: false, isReviewing: false) }
            return (canStepBack: self.answerHistory.canStepBack, isReviewing: self.answerHistory.isReviewing)
        }
        HotKeyCenter.shared.register(keyCode: UInt32(kVK_Space), modifiers: UInt32(cmdKey | shiftKey)) { [weak self] in
            self?.notch.toggleVisibility()
        }
        HotKeyCenter.shared.register(keyCode: UInt32(kVK_ANSI_P), modifiers: UInt32(cmdKey | shiftKey)) { [weak self] in
            self?.toggleRecording()
        }
        // 回看上一条回答。单键循环：退到最早一条后再按即回到当前，因此不必再占一个
        // 全局热键——每多注册一个组合键，就多抢走一次 Zoom/浏览器里的同名快捷键。
        HotKeyCenter.shared.register(keyCode: UInt32(kVK_ANSI_B), modifiers: UInt32(cmdKey | shiftKey)) { [weak self] in
            self?.answerHistory.stepBack()
        }
        // The interviewer has been silent for the whole timeout window → stop recording
        // (back to armed/ready), so a forgotten session doesn't keep uploading silence.
        inactivity.onTimeout = { [weak self] in self?.autoStopForInactivity() }
    }

    /// 进程退出前的收尾。菜单里的「退出」走 NSApp.terminate，不经过 stopRecording——
    /// 而 sessions.end() 只在那里调用，于是录音中直接退出会把整场复盘丢掉（record()
    /// 只改了内存里的当前会话）。stopRecording 幂等，未在录音时这里什么也不做。
    func prepareForTermination() {
        if recording { stopRecording() } else { sessions.end() }
    }

    /// (Re)start the pipeline per AppConfig + current keys. Called at launch and
    /// whenever keys change from the menu.
    private func reloadPipeline() {
        // 录音中重载（设置页改 Key、钱包兑换带 Key 的码）必须走完整停止路径：
        // 否则 credit.endSession() 被跳过，计量计时器失去 owner 继续每秒扣费，
        // 而 `.exhausted` 又因 recording 已被置 false 而被吞掉 → 静默扣到清零。
        // stopRecording 幂等，重复调用安全。
        if recording { stopRecording() }
        stt?.stop(); audio?.stop(); inactivity.stop()
        credit.endSession()   // 兜底：任何路径进来都保证表已停
        stopConnectionKeepWarm()
        setRecording(false)
        // 配置变了（换成自己的 Key 就不再计量）→ 旧的额度提示不再成立，先撤掉。
        notch.model.prompt = nil
        stt = nil; audio = nil; turn = nil; captureStarted = false
        switch AppConfig.pipeline {
        case .demo:
            runDemo()
        case .mock:
            armPipeline(stt: MockSttClient(), generator: MockAnswerGenerator())
        case .live:
            armLive()
        case .auto:
            // Arm live iff a real STT engine resolves (Apple on-device needs no key; Deepgram
            // needs a key). Only sit idle when neither is available (would be Mock).
            if ProviderRegistry.sttResolution() != .mock {
                armLive()
            } else {
                idleNoKey() // no usable STT engine → sit idle (no mock loop)
            }
        }
        NSLog("[app] pipeline (re)loaded")
    }

    /// .auto with no key: armed-but-can't-record. Distinct from `.ready` only in the
    /// message — crucially NOT `.listening`, so the notch never implies it's recording.
    private func idleNoKey() {
        notch.model.recording = false
        notch.model.status = .ready
        notch.model.message = .apiKeyMissing
        notch.model.answer = ""
        notch.model.errorDetail = nil
        notch.model.intentLabel = ""
        notch.model.question = ""
        NSLog("[app] idle — no Deepgram key; set it in the menu")
    }

    /// Explicit per-session gate. Nothing is captured or uploaded until this runs; the
    /// pipeline is only *armed* at launch (see `armLive`). Invoked by ⌘⇧P, the notch
    /// Start/Stop control, and the menu.
    private func toggleRecording() {
        guard stt != nil else { return }   // demo / no-key → nothing to record
        recording ? stopRecording() : startRecording()
    }

    /// Open the audio tap + STT socket and begin uploading the call-app channel.
    private func startRecording() {
        // 待机期间面试语言被改过 → 兑现设置页「下一次开始录音时生效」的承诺：
        // 就地重建管线（STT 语言/路由 prompt/回合门控随新语言重新装配），再继续开始。
        // reloadPipeline 未在录音时是纯重装配，不触碰音频权限与计量。
        if !recording, stt != nil, armedInterviewLanguage != Settings.interviewLanguage {
            NSLog("[live] interview language changed (%@ → %@) — re-arming pipeline before start",
                  armedInterviewLanguage.rawValue, Settings.interviewLanguage.rawValue)
            reloadPipeline()
        }
        guard let stt, !recording else { return }
        // 额度硬闸：本场会用到受管服务且余额为 0 → 不开始，引导充值。
        // 全 BYO/本地的会话不经过这道闸（不计量的东西永远不拦）。
        let metered = CreditPolicy.sessionIsMetered()
        if metered, !credit.canStartMeteredSession {
            presentCreditPrompt()
            return
        }
        // Live pipeline only: capture/upload NOTHING until the user has seen and accepted
        // exactly what leaves the device (call-app audio → Deepgram; question/context → LLM).
        if audio != nil, !ensureRecordingConsent() { return }
        // Re-warm at session start: the arm-time warm connection has likely idled out by the
        // time the interview actually begins, and the FIRST question is the worst moment to
        // pay TLS/H2 cold-start (§14.4). Sends no user data — a 1-token ping.
        prewarmLLM()
        // 热词取开录一刻的最新值：最常见的「填完简历事实/换稿 → 直接开始录音」流程
        // 不经过 reloadPipeline，arm 时下发的那份是旧快照。答案库同理对齐当前目标。
        stt.setVocabulary(sttContextualVocabulary())
        bank.activate(targetID: targetStore.activeID)
        rebuildPortrait()
        do {
            // Open the audio tap FIRST so that "no call app to capture" throws before the STT
            // socket opens — we never start uploading when there is nothing to capture.
            if let audio { try audio.start(); captureStarted = true; inactivity.start() }
            try stt.start()
            // 新一场面试：上一场的回答不能出现在这一场的回看里（拿上一家公司的答案
            // 回答这一家，正是这个 app 最不能犯的错）。
            answerHistory.reset()
            sttHealth.reset()   // 上一场的慢终稿计数不跨场
            sessions.begin(scriptName: scriptStore.active?.displayLabel,
                           targetID: targetStore.activeID,
                           targetCompany: targetStore.active?.company)
            setRecording(true)
            credit.beginSession(metered: metered)
            startConnectionKeepWarm()
            enterListening()
        } catch AudioError.noCallApp {
            audio?.stop(); inactivity.stop()
            captureStarted = false
            setRecording(false)
            enterReady()
            presentNoCallAppAlert()
        } catch {
            audio?.stop(); stt.stop(); inactivity.stop()
            captureStarted = false
            setRecording(false)
            NSLog("[live] start recording failed: %@", String(describing: error))
            notch.model.status = .error
            notch.model.message = .startupError
            notch.model.errorDetail = error.localizedDescription
        }
    }

    /// One-time (per disclosure version) data-use gate shown before the first live recording.
    /// Returns true if the user has consented — now or previously. Honest by construction:
    /// nothing is captured or uploaded until this returns true. Bumping
    /// `Settings.currentConsentVersion` re-prompts everyone with the updated terms.
    private func ensureRecordingConsent() -> Bool {
        if Settings.recordingConsentVersion >= Settings.currentConsentVersion { return true }
        let t = AppStrings.current
        let alert = NSAlert()
        alert.messageText = t.consentTitle
        alert.informativeText = t.consentBody(llm: currentLLMName(),
                                              sttLocal: ProviderRegistry.sttResolution() == .apple,
                                              sendsContext: Settings.sendContextToLLM)
        alert.addButton(withTitle: t.consentAgree)    // .alertFirstButtonReturn (default)
        alert.addButton(withTitle: t.consentCancel)
        NSApp.activate(ignoringOtherApps: true)
        let agreed = alert.runModalGuarded() == .alertFirstButtonReturn
        if agreed { Settings.recordingConsentVersion = Settings.currentConsentVersion }
        return agreed
    }

    /// Refuse to silently fall back to capturing all system audio: ask the user to open their
    /// call app (or pick one in settings), rather than recording everything.
    private func presentNoCallAppAlert() {
        let t = AppStrings.current
        let alert = NSAlert()
        alert.messageText = t.noCallAppTitle
        alert.informativeText = t.noCallAppBody
        alert.addButton(withTitle: t.openPrivacySettings)
        alert.addButton(withTitle: t.cancel)
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModalGuarded() == .alertFirstButtonReturn { openSettings(section: .privacy) }
    }

    /// Name of the LLM the live pipeline will actually use (mirrors `ProviderRegistry`),
    /// so the consent disclosure names the real recipient of the question + context.
    private func currentLLMName() -> String {
        ProviderRegistry.llmDisplayName() ?? "AI"
    }

    /// End the session: tear the tap + STT socket fully down so nothing is captured or
    /// uploaded while idle, and return to the armed/ready state.
    private func stopRecording() {
        audio?.stop()
        stt?.stop()
        inactivity.stop()
        credit.endSession()
        stopConnectionKeepWarm()
        captureStarted = false
        setRecording(false)
        // R1 的降级只在本场有效：下一场重新按偏好解析（网络可能已经恢复，
        // Deepgram 的识别质量仍然更好）。就地换回解析结果，不重载整条管线。
        if sttDegradedThisSession {
            sttDegradedThisSession = false
            sttHealth.reset()
            sttSwitchRevertWork?.cancel()
            let fresh = ProviderRegistry.makeStt()
            attachSttHandlers(fresh)
            routeAudio(to: fresh)
            stt = fresh
        }
        // 本场落盘供复盘。stopRecording 是幂等的（多条 teardown 路径都会走到），
        // SessionStore.end 对「没有进行中的会话」同样幂等。
        sessions.end()
        enterReady()
    }

    /// InactivityMonitor timeout: the interviewer has been silent for the whole window
    /// → stop the session so it doesn't keep uploading silence, with a clear notice.
    private func autoStopForInactivity() {
        guard recording else { return }
        NSLog("[app] auto-stop: no interviewer speech for %d s", Int(inactivity.seconds))
        stopRecording()
        notch.model.message = .autoStopped
    }

    // MARK: - 额度（计量 · 预警 · 拦截）

    /// 余额/计量状态 → 刘海额度胶囊（仅计量会话中显示）；预警/耗尽 → 提示与停止。
    private func observeCredit() {
        credit.$balanceSeconds.combineLatest(credit.$meteringActive)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] balance, metering in
                guard let self else { return }
                self.notch.model.creditSeconds = metering ? balance : nil
                // 充值到账（钱包里兑换了码）→ 刘海里的「额度已用完」自行退场：
                // 事情已经被解决了，不该还要用户回来手动关掉一次提示。
                guard balance > 0, self.notch.model.prompt == .credit else { return }
                self.notch.model.prompt = nil
                if !self.recording, self.notch.model.message == .creditExhausted {
                    self.notch.model.message = .ready
                }
            }
            .store(in: &creditCancellables)
        credit.onAlert = { [weak self] alert in
            DispatchQueue.main.async { self?.handleCreditAlert(alert) }
        }
    }

    private func handleCreditAlert(_ alert: CreditManager.Alert) {
        switch alert {
        case .low:
            // 轻提示：状态行短暂切到「额度即将用完」，几秒后回到聆听态。
            // 具体剩余时间由额度胶囊的 mm:ss 倒计时持续显示，这里不打断面试。
            guard recording else { return }
            notch.model.message = .creditLow
            creditLowRevertWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.recording, self.notch.model.message == .creditLow else { return }
                self.notch.model.message = .listening
            }
            creditLowRevertWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
        case .exhausted:
            // CreditManager 已自行停表；这里只负责把管线停下并告知用户。
            // 不再 `guard recording` 提前返回——那正是「表还在走、通知被吞」的成因。
            NSLog("[credit] exhausted — stopping session")
            let wasRecording = recording
            if wasRecording { stopRecording() }   // → enterReady() 会先清掉旧提示
            notch.model.message = .creditExhausted
            if wasRecording { presentCreditPrompt() }
        }
    }

    /// 额度用完（面试中途耗尽 / 余额为 0 无法开始）：把下一步放进刘海，**不弹模态**。
    ///
    /// 采集侧的洞已由 `runModalGuarded()`（ScreenShareGuard）堵上，弹窗不会再进共享画面；
    /// 但模态还剩一处硬伤治不了：`NSApp.activate(ignoringOtherApps:)` 会把焦点从面试 App
    /// 抢走，且 `runModal()` 阻塞 run loop——正在说话、正在共享屏幕的那一刻尤其致命。
    /// 刘海本体既不抢焦点也不阻塞，且本来就在 `sharingType = .none` 的面板里。
    private func presentCreditPrompt() {
        notch.model.message = .creditExhausted
        notch.model.prompt = .credit
    }

    /// 刘海内提示的按钮：先撤掉提示，再执行。两条实际动作都会打开自己的窗口/浏览器，
    /// 但那是用户刚刚点下去要求的，与「凭空抢焦点」不是一回事。
    private func handleNotchPromptAction(_ action: NotchPromptAction) {
        notch.model.prompt = nil
        switch action {
        case .topUp: NSWorkspace.shared.open(Provisioning.buyURL)
        case .enterCode: openSettings(section: .wallet)
        case .dismiss: break
        }
    }

    /// Snapshot for the status-bar self-check (PLAN §3 S1 readiness).
    private func currentHealth() -> ControlPanel.Health {
        let now = DispatchTime.now().uptimeNanoseconds
        let dgKey = Settings.apiKey("DEEPGRAM_API_KEY") != nil
        let llm = ProviderRegistry.llmDisplayName()
        let voiced = audio?.lastVoicedUptimeNs ?? 0
        let voicedFresh = voiced != 0 && now &- voiced < 5_000_000_000
        // Readiness = tap started OK while recording — NOT "frames flowing": the tap only
        // streams while system audio is active, so silence ≠ broken.
        let captureOK = recording && captureStarted
        let state: CaptureHealthState
        if !recording { state = audio == nil ? .noKeyOrDemo : .notStarted } // standby, not an error
        else if !captureStarted { state = .permissionRequired }
        else if voicedFresh { state = .voiceDetected }
        else { state = .ready }
        return .init(recording: recording, captureOK: captureOK, captureState: state,
                     sttConnected: stt?.isConnected ?? false, deepgramKey: dgKey, llm: llm,
                     llmChinaBlocked: ProviderRegistry.llmChinaBlocked(),
                     // 全窗口审计，不再只看刘海一个窗口（E6：字面真语义假）。
                     screenShareGuard: ScreenShareGuard.auditPasses(),
            activeScript: scriptStore.active?.displayLabel,
            hasScriptsButNoneActive: scriptStore.activeID == nil && !scriptStore.all.isEmpty,
                     activeTarget: targetStore.active?.displayLabel,
                     // 只对「会被计量」的配置显示额度——全 BYO 的用户没有额度概念。
                     creditSeconds: CreditPolicy.sessionIsMetered() ? credit.balanceSeconds : nil)
    }

    /// Warm the LLM HTTPS/H2 connection at arm time so the FIRST interview question doesn't
    /// pay TLS/connection cold-start (PLAN §14.4 「启动即预热」). The Deepgram WS opens later,
    /// when recording actually starts. `URLSession.shared` pools by host, so this warms the
    /// exact connection generate()/router reuse. Sends no user audio — only a 1-token ping.
    private func prewarmLLM() {
        // 解析全部挪进后台 task：llmResolution/llmFallbackResolution 内是多次同步
        // Keychain XPC（重签名后还可能是 ACL 弹框），而本函数在主线程被 armLive 与
        // 60s 保温定时器反复调用。
        func warm(_ label: String, _ resolve: @escaping @Sendable () -> LLMResolution?) {
            Task.detached(priority: .utility) {
                guard let r = resolve() else { return }
                let t0 = DispatchTime.now().uptimeNanoseconds
                _ = try? await FastLLM.complete(system: "warmup", user: ".", maxTokens: 1,
                                                resolution: r)
                let ms = Double(DispatchTime.now().uptimeNanoseconds &- t0) / 1_000_000
                NSLog("[prewarm] %@ (%@) warmed in %dms", label, String(describing: r), Int(ms))
            }
        }
        warm("LLM connection") {
            let r = ProviderRegistry.llmResolution()
            return r == .none ? nil : r
        }
        // 候补也要焐热：首 token 看门狗切换发生时，现付 DNS+TLS+H2 的正是降级链
        // 第二家——而那必然落在「主选已经 3s 没吐字」的最不能再等的一问上。域内
        // 候补（qwen⇄deepseek）走 directSession 池，与主选不共享连接。被墙的候补
        // 不焐：国内残留的 Gemini/Claude key 会让每次保温 ping 各挂满一个超时。
        warm("fallback") {
            guard let fb = ProviderRegistry.llmFallbackResolution(),
                  !Settings.llmBlockedInChina(fb, inChina: Settings.isLikelyInChina())
            else { return nil }
            return fb
        }
    }

    /// 会话期间的连接保温。
    ///
    /// 预热此前只在 arm 与 startRecording 各打一枪。面试官讲了几分钟题干之后，H2 连接
    /// 已被服务端或 NAT 回收，下一问要重付 DNS + TLS + H2 建连——中国区跨运营商可达
    /// 1s 以上，而它**必然**落在「对方讲了很久的那道复杂题」上，正是最不能超时的一问。
    /// 每 60s 一发 1-token ping，不含任何用户数据。
    private func startConnectionKeepWarm() {
        connectionKeepWarm?.invalidate()
        guard ProviderRegistry.llmResolution() != .none else { return }
        let t = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            guard let self, self.recording else { return }
            self.prewarmLLM()
        }
        t.tolerance = 10
        RunLoop.main.add(t, forMode: .common)
        connectionKeepWarm = t
    }

    private func stopConnectionKeepWarm() {
        connectionKeepWarm?.invalidate()
        connectionKeepWarm = nil
    }

    private func makeRouter() -> Router {
        ProviderRegistry.llmResolution() != .none
            ? LLMRouter(language: armedInterviewLanguage) : NullRouter()
    }

    /// Open the settings window (optionally at a section). Lazily created and reused; shares
    /// the live `scriptStore`, so script picks/edits take effect on the next turn with no
    /// pipeline restart. Key changes reload the pipeline (may flip mock⇄live).
    private func openSettings(section: SettingsSection? = nil) {
        if settingsWindow == nil {
            let s = SettingsWindowController(store: scriptStore, factStore: facts, sessionStore: sessions)
            s.onKeysChanged = { [weak self] in self?.reloadPipeline() }
            s.onBuildBank = { [weak self] in self?.runPrep() }
            s.onDeleteData = { [weak self] in
                let failures = LocalData.deleteAll()
                // 内存里的复盘记录必须一并清掉。只删文件的话：复盘页照样列出已删的
                // 转录，而下一次会话结束时 save() 会把内存中留存的整份历史又写回磁盘
                // ——「已删除」当场变成假话。
                self?.sessions.clear()
                self?.facts.reload(); self?.bank.reload(); self?.scriptStore.reload(); self?.reloadPipeline()
                // 「已删除」是一句隐私承诺，不能建立在被吞掉的错误上。
                guard !failures.isEmpty else { return }
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = AppStrings.current.deleteIncompleteTitle
                alert.informativeText = AppStrings.current.deleteIncompleteBody(
                    failures.joined(separator: ", "))
                alert.addButton(withTitle: AppStrings.current.ok)
                alert.runModalGuarded()
            }
            s.onRerunOnboarding = { [weak self] in self?.openOnboarding() }
            settingsWindow = s
        }
        settingsWindow?.show(section: section)
    }

    /// Open the workbench (备战驾驶舱). Lazily created and reused; shares the same live
    /// stores as settings & pipeline, so ammo edits/target picks take effect on the next
    /// turn with no restart.
    private func openWorkbench() {
        if workbench == nil {
            let wb = WorkbenchWindowController(targets: targetStore, scripts: scriptStore,
                                               facts: facts)
            wb.onOpenSettings = { [weak self] section in self?.openSettings(section: section) }
            wb.onBuildBank = { [weak self] in self?.runPrep() }
            wb.onPipelineChanged = { [weak self] in
                self?.facts.reload()
                self?.rebuildPortrait()
            }
            wb.healthProvider = { [weak self] in self?.currentHealth() ?? .empty }
            wb.bankCountProvider = { [weak self] in self?.bank.entries.count ?? 0 }
            wb.onPrepare = { [weak self] target in self?.prepareForInterview(target) }
            wb.onArmTarget = { [weak self] id in self?.applyTarget(id) }
            workbench = wb
        }
        workbench?.show()
    }

    /// 武装一个目标：设为活跃 → 兑现其绑定用稿 → 切它的答案库 → 画像/热词跟上。
    /// 菜单选目标与「准备面试」共用这一条路径（真相源只有一处）。
    private func applyTarget(_ id: String?) {
        targetStore.setActive(id)
        if let target = targetStore.active {
            // 一司一稿：目标绑了稿就切过去；没绑就保持现状（不静默换稿）。
            if let scriptID = target.scriptID,
               scriptStore.all.contains(where: { $0.id == scriptID }) {
                scriptStore.setActive(scriptID)
            }
        }
        bank.activate(targetID: targetStore.activeID)
        rebuildPortrait()
        stt?.setVocabulary(sttContextualVocabulary())
    }

    /// armed 阶段（点「准备面试」）：武装目标 → 预热连接 → Genie 吸入刘海待命。
    /// **不开录音、不计费**——仪式感与计费诚实解耦；录音仍由既有三入口
    /// （⌘⇧P / 刘海按钮 / 菜单）在面试真正开始时开启。
    private func prepareForInterview(_ target: InterviewTarget) {
        applyTarget(target.id)
        prewarmLLM()
        notch.show()   // 落点必须在场，飞行 Panel 才能压到它下面
        let flew: Bool = {
            guard let win = workbench?.windowForFlight,
                  let sheet = workbench?.flightSheetModel() else { return false }
            return GenieFlight.fly(from: win,
                                   sheet: sheet,
                                   to: notch.collapsedFrame,
                                   belowWindowNumber: notch.panelWindowNumber,
                                   onMouthReached: { [weak self] in self?.notch.inhaleArmed() },
                                   completion: { [weak self] in self?.notch.pulseArmed() })
        }()
        // 快照已接管（或走降级直切）：真窗此刻退场。降级 = Reduce Motion / 无 Metal /
        // 快照失败——直接收窗 + 光场脉冲，仪式绝不挡住 armed 本体。
        workbench?.hideForFlight()
        if !flew { notch.pulseArmed() }
    }

    /// First-launch (or menu-reopened) onboarding. Step 1 reuses the live `scriptStore`,
    /// step 2 fires the real macOS audio-capture TCC prompt, step 3 drives the real notch.
    private func openOnboarding() {
        if onboarding == nil {
            let ob = OnboardingWindowController()
            ob.loadScript = { [weak self] in self?.scriptStore.asConventionText() ?? "" }
            ob.onSaveScript = { [weak self] text in
                guard let self else { return 0 }
                let entries = ScriptParser.parse(text)
                guard !entries.isEmpty else { return 0 }
                // Onboarding maintains a single script: update the active one, or create it.
                if let active = self.scriptStore.active {
                    self.scriptStore.update(id: active.id, entries: entries)
                } else {
                    self.scriptStore.add(name: AppStrings.current.scriptOnboardingName, entries: entries)
                }
                NSLog("[script] imported %d entries via onboarding", entries.count)
                return entries.count
            }
            ob.onRequestPermission = { [weak self] done in self?.probeSystemAudioPermission(done) }
            // Key resolution mirrors the live pipeline (Keychain ∪ env), so the onboarding's
            // readiness check matches what `reloadPipeline` will actually do.
            ob.keyPresent = { Settings.apiKey($0) != nil }
            // Persist only — going live is deferred to `onFinish`'s reloadPipeline so no audio
            // tap starts while onboarding is still open.
            ob.onSaveKey = { name, value in
                let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if v.isEmpty { Secrets.delete(name) } else { Secrets.set(name, v) }
            }
            ob.onPlayDemo = { [weak self] answer, intent, spokenJa in self?.runOnboardingDemo(answer: answer, intent: intent, spokenJa: spokenJa) }
            // 目标步：按公司名 upsert（引导可重开、完成页可重复到达——不许因此长出重复目标）。
            ob.onSaveTarget = { [weak self] company, role in
                guard let self else { return }
                let cleanRole = role.isEmpty ? nil : role
                if let existing = self.targetStore.all.first(where: {
                    $0.company.compare(company, options: .caseInsensitive) == .orderedSame
                }) {
                    self.targetStore.update(id: existing.id, role: .some(cleanRole))
                    self.targetStore.setActive(existing.id)
                } else if let id = self.targetStore.add(company: company, role: cleanRole) {
                    self.targetStore.setActive(id)
                }
                self.rebuildPortrait()
            }
            ob.onImportResume = { [weak self] url in self?.pendingOnboardingResume = url }
            #if DEBUG
            // 视觉 QA：FI_QA_DEMO_LIVE=1 让引导 demo 步按「面试录音进行中」渲染（🔇 提示）。
            let qaDemoLive = ProcessInfo.processInfo.environment["FI_QA_DEMO_LIVE"] == "1"
            ob.isLiveCapture = { [weak self] in qaDemoLive || (self?.recording ?? false) }
            #else
            ob.isLiveCapture = { [weak self] in self?.recording ?? false }
            #endif
            ob.onFinish = { [weak self] _, _ in
                guard let self else { return }   // script already persisted on import
                Settings.onboarded = true
                self.onboarding = nil
                self.reloadPipeline()            // resync notch after the demo
                // 引导的终点不是空气，是驾驶舱：落到工作台；带简历的接着走解析确认流。
                self.openWorkbench()
                if let url = self.pendingOnboardingResume {
                    self.pendingOnboardingResume = nil
                    self.workbench?.importResume(url)
                }
            }
            onboarding = ob
        }
        onboarding?.show()
    }

    /// Fire the real macOS audio-capture permission prompt by briefly probing a tap.
    /// Only the .app bundle can be granted (PLAN §3 / README); in `swift run` this just
    /// reports `false` and onboarding still proceeds.
    private func probeSystemAudioPermission(_ done: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let probe = AudioCaptureFactory.makeProbe()
            var ok = false
            do { try probe.start(); ok = true } catch { ok = false }
            probe.stop()
            DispatchQueue.main.async { done(ok) }
        }
    }

    /// Scripted demo on the REAL notch (interviewer Q → streamed answer). The onboarding
    /// passes the user's OWN imported answer verbatim, so the demo shows exactly what the
    /// live app will surface on a question match. Pacing targets ~1.6s regardless of length.
    /// `spokenJa` is the interviewer's question spoken aloud (always Japanese). While it
    /// plays we pause the live turn pipeline so our own TTS isn't captured by the audio tap
    /// and answered for real — the scripted notch demo stays authoritative.
    private func runOnboardingDemo(answer: String, intent: String, spokenJa: String) {
        let model = notch.model

        // 只有 TTS 真出声时才需要暂停真转录管线（防自己的音频 tap 采到 demo 语音后
        // 抢答）。录音进行中 demo 是静音的（E5）——那时暂停只会白丢一段真实转录，
        // 管线照常跑，真问题到达时 demo 让路（见下方接管检查）。
        if demoVoice.speakJapanese(spokenJa, liveCaptureActive: recording) {
            turn?.paused = true
            demoUnpauseWork?.cancel()
            let resume = DispatchWorkItem { [weak self] in self?.turn?.paused = !(self?.recording ?? false) }
            demoUnpauseWork = resume
            // Cover the spoken question (~0.18s/char for JA TTS) plus the streamed answer + grace.
            let window = Double(spokenJa.count) * 0.18 + 3.0
            DispatchQueue.main.asyncAfter(deadline: .now() + window, execute: resume)
        }

        let perChar = max(UInt64(12_000_000), 1_600_000_000 / UInt64(max(1, answer.count)))
        Task { @MainActor in
            model.intentLabel = intent
            model.question = spokenJa   // preview the live recognized-question row
            model.message = .thinking
            model.answer = ""
            model.errorDetail = nil
            model.status = .thinking
            try? await Task.sleep(nanoseconds: 650_000_000)
            // 接管检查：录音中管线不暂停，真回合一旦写入自己的问题，demo 必须立刻
            // 住手——否则两路会交错写同一个 answer，真答案被 demo 字符污染。
            guard model.question == spokenJa else { return }
            model.message = .suggesting
            model.status = .streaming
            for ch in answer + "\n" {
                guard model.question == spokenJa else { return }
                model.answer.append(ch)
                try? await Task.sleep(nanoseconds: perChar)
            }
            guard model.question == spokenJa else { return }
            model.message = .completed
            model.status = .presenting
        }
    }

    /// Offline answer-bank build (FI_PREP=1). Runs to completion then keeps running.
    private func runPrep() {
        let pre = PreGenerator(facts: facts, bank: bank)
        Task { @MainActor in
            notch.model.message = .bankGenerating
            await pre.generate { done, total in
                NSLog("[prep] %d/%d", done, total)
            }
            notch.model.message = notch.model.recording ? .listening : .ready
        }
    }

    /// Wire a mock STT → TurnManager → notch, but leave it armed (not started): the user
    /// presses Start (⌘⇧P / notch) to begin, same gate as the live pipeline.
    private func armPipeline(stt: SttClient, generator: AnswerGenerator) {
        armedInterviewLanguage = Settings.interviewLanguage
        rebuildPortrait()
        let tm = TurnManager(model: notch.model, generator: generator,
                             knowledge: facts, router: makeRouter(), bank: bank, scriptStore: scriptStore,
                             answerHistory: answerHistory, portrait: portrait)
        tm.interviewLanguage = armedInterviewLanguage
        tm.onTurnRecorded = { [weak self] q, a, source in
            self?.sessions.record(question: q, answer: a, source: source)
        }
        tm.onTurnRetracted = { [weak self] q in self?.sessions.retractLast(question: q) }
        tm.paused = true
        stt.onTranscript = { [weak tm] t in
            DispatchQueue.main.async { tm?.handleTranscript(t) }
        }
        stt.onError = { err in NSLog("[stt] error: %@", String(describing: err)) }
        self.turn = tm
        self.stt = stt
        enterReady()
    }

    /// Armed and waiting: nothing is captured or uploaded. The user starts a session.
    private func enterReady() {
        notch.model.answer = ""
        notch.model.errorDetail = nil
        notch.model.intentLabel = ""
        notch.model.question = ""
        notch.model.recording = false
        notch.model.message = .ready
        notch.model.status = .ready
        notch.model.prompt = nil
    }

    private func enterListening() {
        notch.model.answer = ""
        notch.model.errorDetail = nil
        notch.model.intentLabel = ""
        notch.model.question = ""
        notch.model.recording = true
        notch.model.message = .listening
        notch.model.status = .listening
        notch.model.prompt = nil
    }

    /// Arm the live pipeline: build providers, wire the audio→STT→turn→notch graph, and warm
    /// the LLM connection — but DO NOT open the audio tap or the Deepgram socket. The app sits
    /// armed-and-silent until the user explicitly starts recording (privacy default, option A).
    private func armLive() {
        prewarmLLM()
        // 快照先行：makeStt/makeRouter/TurnManager 三者的语言必须取自同一时刻。
        armedInterviewLanguage = Settings.interviewLanguage
        let generator = ProviderRegistry.makeGenerator()
        let sttc = ProviderRegistry.makeStt()
        rebuildPortrait()
        let tm = TurnManager(model: notch.model, generator: generator,
                             knowledge: facts, router: makeRouter(), bank: bank, scriptStore: scriptStore,
                             answerHistory: answerHistory, portrait: portrait)
        tm.interviewLanguage = armedInterviewLanguage
        tm.onTurnRecorded = { [weak self] q, a, source in
            self?.sessions.record(question: q, answer: a, source: source)
        }
        tm.onTurnRetracted = { [weak self] q in self?.sessions.retractLast(question: q) }
        tm.paused = true   // ignore transcripts until the session actually starts
        self.turn = tm

        attachSttHandlers(sttc)

        let capture = AudioCaptureFactory.make()
        self.audio = capture
        routeAudio(to: sttc)
        // Faithful §4 T0: use the audio path's last-voiced time (≈ last phoneme).
        tm.latency.voicedClock = { [weak capture] in capture?.lastVoicedUptimeNs ?? 0 }
        // R1：每轮的 STT 交付耗时喂给慢终稿探测（连续超阈值 → 热切换端侧引擎）。
        tm.latency.onSttFinalDelay = { [weak self] ms in self?.noteSttDelivery(ms) }

        self.stt = sttc
        enterReady()
    }

    /// 把 STT 客户端接进管线的全部回调（转写 / 资产下载 / 断连重连 / 错误）。
    /// armLive 与 R1 的中途热切换共用——两处各接一份迟早漏改一处。
    private func attachSttHandlers(_ sttc: SttClient) {
        // 域名词热词随管线装配下发（Apple → contextualStrings 端侧；Deepgram → 仅日语
        // keywords boost）。走协议不下转型：armLive 与 R1 热切换共用本函数，正是
        // 「两处各接一份迟早漏改一处」要防的模式。startRecording 会再刷一次最新值。
        sttc.setVocabulary(sttContextualVocabulary())
        sttc.onTranscript = { [weak self] t in
            if !t.text.isEmpty { self?.inactivity.noteActivity() } // interviewer was heard
            DispatchQueue.main.async { self?.turn?.handleTranscript(t) }
        }
        // 端侧日语资产缺失时（Apple 引擎，macOS 26+）主动下载模型；把进度接到既有的
        // STT 状态/错误通道（`.sttError` + `errorDetail` 会被 NotchPresentation 渲染为整句正文）。
        // 只在具体类上取回调，不改 `SttClient` 协议，避免波及 Deepgram 客户端。
        if let apple = sttc as? AppleSpeechSttClient {
            apple.onAssetDownloadProgress = { [weak self] frac in
                let pct = max(0, min(100, Int(frac * 100)))
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.notch.model.status = .error
                    self.notch.model.message = .sttError
                    self.notch.model.errorDetail = AppStrings.current.sttModelDownloading(pct)
                }
            }
        }
        // 转写连接中断 → 刘海显性提示。30 秒的重连预算期间用户必须知道它没在工作，
        // 否则只是把旧的「静默失联」缩短到 30 秒而已。同 Apple 引擎的资产下载进度，
        // 只在具体类上取回调，不动 SttClient 协议。
        //
        // 恢复时**只还原断连前的状态，绝不 enterListening()**（审计 R5）：旧实现在重连
        // 成功的一瞬清空 model.answer——断连恰好发生在展示答案时（网络抖动最常见的
        // 时机就是通话中），用户正照着念的答案会在嘴巴念到一半时凭空消失。
        if let dg = sttc as? DeepgramSttClient {
            dg.onConnectionChanged = { [weak self] connected in
                DispatchQueue.main.async {
                    guard let self, self.recording else { return }
                    let model = self.notch.model
                    if connected {
                        if let restore = self.sttOutage.noteReconnected(currentMessage: model.message) {
                            model.message = restore.message
                            model.status = restore.status
                        }
                    } else {
                        self.sttOutage.noteDisconnected(currentMessage: model.message,
                                                        currentStatus: model.status)
                        model.message = .sttReconnecting
                    }
                }
            }
        }
        sttc.onError = { [weak self] err in
            NSLog("[stt] error: %@", String(describing: err))
            // Only terminal errors surface to the user; transient socket errors auto-retry
            // and stay log-only (no error-flashing). Deepgram 的永久性故障现在会以
            // `SttError.streamUnavailable` 抵达这里，因此不再被这道过滤器吞掉。
            guard let sttErr = err as? SttError else { return }
            DispatchQueue.main.async {
                guard let self else { return }
                self.notch.model.status = .error
                self.notch.model.message = .sttError
                self.notch.model.errorDetail = err.localizedDescription
                // 终态 STT 故障 = 这场会话不可能再产生转写。继续录音只会让用户白等，
                // 计量会话还在按秒扣费——为一场 STT 从未工作的面试付钱。
                if case .streamUnavailable = sttErr, self.recording {
                    NSLog("[live] terminal STT failure — stopping session")
                    self.stopRecording()
                    self.notch.model.status = .error
                    self.notch.model.message = .sttError
                    self.notch.model.errorDetail = err.localizedDescription
                }
            }
        }
    }

    /// STT 热词：公司名、职务、技能、志望公司。这些字段本身就是词粒度，不需要
    /// 分词；专有名词正是端侧 zh-CN/ja-JP 识别最容易听错、且下游完全救不回的一类。
    /// 全程不受 sendContextToLLM 门控：Apple 路径一个字节都不出网，Deepgram 路径
    /// 与音频本体走同一条既经同意的通道。
    private func sttContextualVocabulary() -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        func add(_ raw: String?) {
            guard let raw else { return }
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard t.count >= 2, t.count <= 20, seen.insert(t).inserted else { return }
            out.append(t)
        }
        // 武装目标（一司一策）排最前——热词表被 prefix(50) 截断时，最不能丢的就是它。
        // JD 刻意不自动抽词（决策⑤只留字段）：长文分词的杂草会反噬识别，
        // 目标级热词走 emphasis.keywords（用户手挑的才配进这张小而准的表）。
        add(targetStore.active?.company)
        add(targetStore.active?.role)
        targetStore.active?.emphasis?.keywords?.forEach { add($0) }
        add(scriptStore.active?.company)
        for m in facts.sheet.motivations { add(m.targetCompany) }
        for e in facts.sheet.experiences { add(e.org); add(e.role) }
        for e in facts.sheet.experiences { e.skills.forEach { add($0) } }
        return Array(out.prefix(50))   // 热词表要小而准，杂草会反噬识别
    }

    /// 音频链路 → 指定 STT 客户端。声级总线永远在路上（刘海光场不因换引擎熄灭）。
    private func routeAudio(to sttc: SttClient?) {
        audio?.onPCM = { [weak sttc] pcm in
            VoiceLevelBus.shared.push(pcm16: pcm)   // 声级 → 刘海光场（听声起伏）
            sttc?.write(pcm)
        }
    }

    // MARK: - R1：慢终稿 → 面试中热切换端侧引擎

    /// LatencyMonitor 上报的每轮 STT 交付耗时（主线程）。只在「用户没有手动钉死引擎
    /// （.auto）+ 当前在用 Deepgram + 本场还没切换过」时喂探测器——`.auto` 的承诺
    /// 就是替用户做对的选择，而它此前只是开机时的一次性时区猜测，面试中从不重估。
    private func noteSttDelivery(_ ms: Double) {
        guard recording, !sttDegradedThisSession,
              Settings.sttEngine == .auto, stt is DeepgramSttClient else { return }
        NSLog("[stt-health] final delivery %dms (threshold %dms)", Int(ms), Int(sttHealth.thresholdMs))
        guard sttHealth.note(deliveryMs: ms) else { return }
        degradeSttToApple()
    }

    /// 连续慢终稿 → 就地切到 Apple 端侧识别，录音不断、回合状态机不动。
    /// 成败都只尝试一次：切换是止损动作，反复横跳只会把两边的冷启动都吃一遍。
    private func degradeSttToApple() {
        sttDegradedThisSession = true
        // 用会话快照而非当前设置：面试中途改语言不许把本场日语音频接给中文识别器。
        let locale = armedInterviewLanguage.appleLocaleID
        guard AppleSpeechSttClient.isReadyForHotSwap(localeID: locale) else {
            // 权限没给过 / 端侧资产没装：中途弹权限框或触发几百 MB 下载比慢更糟。
            // 留在 Deepgram（慢但在工作），只记日志供复盘。
            NSLog("[live] STT finals are slow but Apple on-device isn't ready — staying on Deepgram")
            return
        }
        NSLog("[live] STT finals too slow — hot-swapping to Apple on-device (%@)", locale)
        let old = stt
        let apple = AppleSpeechSttClient(localeID: locale)
        attachSttHandlers(apple)   // 含热词下发
        do { try apple.start() } catch {
            NSLog("[live] Apple STT failed to start (%@) — staying on Deepgram",
                  String(describing: error))
            return
        }
        // 先改道再停旧引擎：缝隙里最多丢极短的一段音频，绝不出现双引擎各出一份终稿。
        routeAudio(to: apple)
        old?.stop()
        stt = apple
        sttHealth.reset()
        // 状态行短暂告知（与 creditLow 同一模式）：几秒后若没被新回合盖掉就回聆听态。
        notch.model.message = .sttSwitchedLocal
        sttSwitchRevertWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.recording,
                  self.notch.model.message == .sttSwitchedLocal else { return }
            self.notch.model.message = .listening
        }
        sttSwitchRevertWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
    }

    /// UI-only scripted smoke test (no pipeline).
    private func runDemo() {
        let model = notch.model
        if let fixture = demoFixtureName() {
            // Let the panel finish its initial collapsed frame before applying the held
            // state; this exercises the real expansion transition in visual QA.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) { [weak self] in
                self?.applyDemoFixture(fixture, to: model)
            }
            return
        }
        Task { @MainActor in
            model.recording = false
            model.status = .ready; model.message = .ready; model.answer = ""; model.intentLabel = ""
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            model.recording = true; model.status = .listening; model.message = .listening
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            model.status = .thinking; model.message = .thinking; model.intentLabel = "自己紹介"
            try? await Task.sleep(nanoseconds: 800_000_000)
            model.status = .streaming; model.message = .suggesting
            for ch in "はい。私の強みは実行力です。ゼミでは周囲と協力しながら課題を整理し、改善策を最後まで実行しました。この経験を活かし、御社でも着実に成果へつなげたいと考えています。" {
                model.answer.append(ch); try? await Task.sleep(nanoseconds: 12_000_000)
            }
            model.status = .presenting; model.message = .completed
        }
    }

    private func demoFixtureName() -> String? {
        let process = ProcessInfo.processInfo
        if let fixture = process.environment["FI_UI_DEMO_STATE"] { return fixture }
        guard let flag = process.arguments.firstIndex(of: "--ui-state"),
              process.arguments.indices.contains(flag + 1) else { return nil }
        return process.arguments[flag + 1]
    }

    /// Stable visual fixtures for local QA (`FI_UI_DEMO=1 FI_UI_DEMO_STATE=presenting`).
    /// They never run unless explicitly requested through the development environment.
    private func applyDemoFixture(_ fixture: String, to model: AnswerModel) {
        let answer = "はい。私の強みは、状況を整理してすぐに行動へ移せる点です。ゼミでは周囲と協力しながら課題を見つけ、改善策を最後まで実行しました。この経験を活かし、御社でも相手の期待を丁寧に捉えながら、着実に成果へつなげたいと考えています。"
        model.answer = ""
        model.errorDetail = nil
        model.intentLabel = ""
        model.question = ""
        model.prompt = nil
        switch fixture {
        case "listening":
            model.recording = true; model.status = .listening; model.message = .listening
        case "thinking":
            model.recording = true; model.status = .thinking; model.message = .thinking
            model.intentLabel = "自己紹介"
        case "streaming":
            model.recording = true; model.status = .streaming; model.message = .suggesting
            model.intentLabel = "自己紹介"; model.answer = String(answer.prefix(86))
        case "presenting":
            model.recording = true; model.status = .presenting; model.message = .completed
            model.intentLabel = "自己紹介"; model.answer = answer
        case "overflow":
            model.recording = true; model.status = .presenting; model.message = .completed
            // 8 段 ≈ 1000 字：必须真的超过 NotchMetrics.maxAnswerHeight，否则这个
            // fixture 就验不到「封顶 + 区内滚动 + 渐隐」那条路径（封顶前 3 段就够溢出屏幕，
            // 封顶后 3 段落在上限之内）。
            model.intentLabel = "長文回答"; model.answer = Array(repeating: answer, count: 8).joined()
        case "error":
            model.recording = true; model.status = .error; model.message = .generationError
            model.errorDetail = "接続を確認してください。"
        case "incomplete":
            // R3：流已提交后断开——答案留在屏上，状态行必须以琥珀色显示
            // 「这段回答可能不完整」，而不是「可直接作答」。
            model.recording = true; model.status = .presenting; model.message = .completed
            model.intentLabel = "自己紹介"; model.answer = String(answer.prefix(120))
            model.errorDetail = AppStrings.current.answerMayBeIncomplete
        case "reconnecting":
            // R4/R5：展示答案途中转写断连——正文保留（重连成功也不清），状态行
            // 显示「正在重连…」，宝石转琥珀「!」（折叠态同一颗宝石）。
            model.recording = true; model.status = .presenting; model.message = .sttReconnecting
            model.intentLabel = "自己紹介"; model.answer = answer
        case "credit-exhausted":
            // 额度用完后的刘海内提示（原先是抢焦点的 NSAlert）。录音已停，但上一轮的答案
            // 还留在屏上——这既是真实场景，也是操作行最容易被顶出卡片的那一版布局：
            // 正文为空的 fixture 永远验不到「答案铺满 → 按钮被裁」那条路径。
            model.recording = false; model.status = .ready; model.message = .creditExhausted
            model.intentLabel = "自己紹介"; model.answer = answer
            model.prompt = .credit
        default:
            model.recording = false; model.status = .ready; model.message = .ready
        }
        if ["thinking", "streaming", "presenting", "overflow", "error",
            "incomplete", "reconnecting", "credit-exhausted"].contains(fixture) {
            model.question = "学生時代に力を入れたことを教えてください。"
        }
        // 视觉 QA：FI_UI_CREDIT=<剩余秒数> 在任意 fixture 上叠加额度胶囊
        // （>600 中性、≤600 琥珀 mm:ss、≤180 红色）。
        if let raw = ProcessInfo.processInfo.environment["FI_UI_CREDIT"], let sec = Int(raw) {
            model.creditSeconds = sec
        }
        // 视觉 QA：FI_UI_REVIEW=<第几条>/<共几条> 叠加回看标识（状态行转琥珀）。
        // 状态机本身由 AnswerHistoryTests 覆盖，这里只为看渲染。
        if let raw = ProcessInfo.processInfo.environment["FI_UI_REVIEW"] {
            let parts = raw.split(separator: "/").compactMap { Int($0) }
            if parts.count == 2 {
                model.review = AnswerModel.ReviewBadge(position: parts[0], count: parts[1])
            }
        }
    }
}
