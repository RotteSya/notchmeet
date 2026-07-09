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
    private let control = ControlPanel()
    private let inactivity = InactivityMonitor()
    private var settingsWindow: SettingsWindowController?
    private var onboarding: OnboardingWindowController?
    private let demoVoice = DemoVoice()
    private var demoUnpauseWork: DispatchWorkItem?
    private var captureStarted = false   // tap.start() succeeded & running (self-check)
    private var recording = false        // explicit session is live (tap + STT uploading)
    private var languageCancellable: AnyCancellable?

    func start() {
        Settings.cleanupLegacyKeys()
        notch.show()
        installEditMenu()
        installControls()
        observeLanguageChanges()
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
        } else if !Settings.onboarded {
            openOnboarding()
        }
    }

    /// A menu-bar-only app has no Edit menu, so ⌘X/⌘C/⌘V key-equivalents aren't
    /// routed to focused text fields. Install a minimal one so paste works.
    private func installEditMenu() {
        let t = AppStrings.current
        let main = NSMenu()
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: t.editMenu)
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

    private func installControls() {
        control.install()
        notch.onSettings = { [weak self] point in self?.control.showMenu(at: point) }
        notch.onToggleRecording = { [weak self] in self?.toggleRecording() }
        control.onMenuVisibilityChanged = { [weak self] open in self?.notch.setSettingsMenuOpen(open) }
        control.onToggleRecording = { [weak self] in self?.toggleRecording() }
        control.recordingProvider = { [weak self] in self?.recording ?? false }
        control.scriptsProvider = { [weak self] in (self?.scriptStore.all ?? [], self?.scriptStore.activeID) }
        control.onSelectScript = { [weak self] id in self?.scriptStore.setActive(id) }
        control.onOpenSettings = { [weak self] in self?.openSettings() }
        control.onManageScripts = { [weak self] in self?.openSettings(section: .scripts) }
        control.healthProvider = { [weak self] in self?.currentHealth() ?? .empty }
        HotKeyCenter.shared.register(keyCode: UInt32(kVK_Space), modifiers: UInt32(cmdKey | shiftKey)) { [weak self] in
            self?.notch.toggleVisibility()
        }
        HotKeyCenter.shared.register(keyCode: UInt32(kVK_ANSI_P), modifiers: UInt32(cmdKey | shiftKey)) { [weak self] in
            self?.toggleRecording()
        }
        // The interviewer has been silent for the whole timeout window → stop recording
        // (back to armed/ready), so a forgotten session doesn't keep uploading silence.
        inactivity.onTimeout = { [weak self] in self?.autoStopForInactivity() }
    }

    /// (Re)start the pipeline per AppConfig + current keys. Called at launch and
    /// whenever keys change from the menu.
    private func reloadPipeline() {
        stt?.stop(); audio?.stop(); inactivity.stop()
        stt = nil; audio = nil; turn = nil; captureStarted = false; recording = false
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
        guard let stt, !recording else { return }
        // Live pipeline only: capture/upload NOTHING until the user has seen and accepted
        // exactly what leaves the device (call-app audio → Deepgram; question/context → LLM).
        if audio != nil, !ensureRecordingConsent() { return }
        // Re-warm at session start: the arm-time warm connection has likely idled out by the
        // time the interview actually begins, and the FIRST question is the worst moment to
        // pay TLS/H2 cold-start (§14.4). Sends no user data — a 1-token ping.
        prewarmLLM()
        do {
            // Open the audio tap FIRST so that "no call app to capture" throws before the STT
            // socket opens — we never start uploading when there is nothing to capture.
            if let audio { try audio.start(); captureStarted = true; inactivity.start() }
            try stt.start()
            recording = true
            turn?.paused = false
            enterListening()
        } catch AudioError.noCallApp {
            audio?.stop(); inactivity.stop()
            captureStarted = false; recording = false
            notch.model.recording = false
            enterReady()
            presentNoCallAppAlert()
        } catch {
            audio?.stop(); stt.stop(); inactivity.stop()
            captureStarted = false
            recording = false
            notch.model.recording = false
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
        let agreed = alert.runModal() == .alertFirstButtonReturn
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
        if alert.runModal() == .alertFirstButtonReturn { openSettings(section: .privacy) }
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
        captureStarted = false
        recording = false
        turn?.paused = true   // drop any in-flight transcript so no answer pops up post-stop
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
                     screenShareGuard: notch.screenShareGuarded)
    }

    /// Warm the LLM HTTPS/H2 connection at arm time so the FIRST interview question doesn't
    /// pay TLS/connection cold-start (PLAN §14.4 「启动即预热」). The Deepgram WS opens later,
    /// when recording actually starts. `URLSession.shared` pools by host, so this warms the
    /// exact connection generate()/router reuse. Sends no user audio — only a 1-token ping.
    private func prewarmLLM() {
        guard ProviderRegistry.llmResolution() != .none else { return }
        Task.detached(priority: .utility) {
            let t0 = DispatchTime.now().uptimeNanoseconds
            _ = try? await FastLLM.complete(system: "warmup", user: ".", maxTokens: 1)
            let ms = Double(DispatchTime.now().uptimeNanoseconds &- t0) / 1_000_000
            NSLog("[prewarm] LLM connection warmed in %dms", Int(ms))
        }
    }

    private func makeRouter() -> Router {
        ProviderRegistry.llmResolution() != .none ? LLMRouter() : NullRouter()
    }

    /// Open the settings window (optionally at a section). Lazily created and reused; shares
    /// the live `scriptStore`, so script picks/edits take effect on the next turn with no
    /// pipeline restart. Key changes reload the pipeline (may flip mock⇄live).
    private func openSettings(section: SettingsSection? = nil) {
        if settingsWindow == nil {
            let s = SettingsWindowController(store: scriptStore)
            s.onKeysChanged = { [weak self] in self?.reloadPipeline() }
            s.onBuildBank = { [weak self] in self?.runPrep() }
            s.onDeleteData = { [weak self] in
                LocalData.deleteAll()
                self?.facts.reload(); self?.bank.reload(); self?.scriptStore.reload(); self?.reloadPipeline()
            }
            s.onRerunOnboarding = { [weak self] in self?.openOnboarding() }
            settingsWindow = s
        }
        settingsWindow?.show(section: section)
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
            ob.onFinish = { [weak self] _, _ in
                guard let self else { return }   // script already persisted on import
                Settings.onboarded = true
                self.onboarding = nil
                self.reloadPipeline()            // resync notch after the demo
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

        turn?.paused = true
        demoUnpauseWork?.cancel()
        let resume = DispatchWorkItem { [weak self] in self?.turn?.paused = !(self?.recording ?? false) }
        demoUnpauseWork = resume
        // Cover the spoken question (~0.18s/char for JA TTS) plus the streamed answer + grace.
        let window = Double(spokenJa.count) * 0.18 + 3.0
        DispatchQueue.main.asyncAfter(deadline: .now() + window, execute: resume)
        demoVoice.speakJapanese(spokenJa)

        let perChar = max(UInt64(12_000_000), 1_600_000_000 / UInt64(max(1, answer.count)))
        Task { @MainActor in
            model.intentLabel = intent
            model.question = spokenJa   // preview the live recognized-question row
            model.message = .thinking
            model.answer = ""
            model.errorDetail = nil
            model.status = .thinking
            try? await Task.sleep(nanoseconds: 650_000_000)
            model.message = .suggesting
            model.status = .streaming
            for ch in answer + "\n" {
                model.answer.append(ch)
                try? await Task.sleep(nanoseconds: perChar)
            }
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
        let tm = TurnManager(model: notch.model, generator: generator,
                             knowledge: facts, router: makeRouter(), bank: bank, scriptStore: scriptStore)
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
    }

    private func enterListening() {
        notch.model.answer = ""
        notch.model.errorDetail = nil
        notch.model.intentLabel = ""
        notch.model.question = ""
        notch.model.recording = true
        notch.model.message = .listening
        notch.model.status = .listening
    }

    /// Arm the live pipeline: build providers, wire the audio→STT→turn→notch graph, and warm
    /// the LLM connection — but DO NOT open the audio tap or the Deepgram socket. The app sits
    /// armed-and-silent until the user explicitly starts recording (privacy default, option A).
    private func armLive() {
        prewarmLLM()
        let generator = ProviderRegistry.makeGenerator()
        let sttc = ProviderRegistry.makeStt()
        let tm = TurnManager(model: notch.model, generator: generator,
                             knowledge: facts, router: makeRouter(), bank: bank, scriptStore: scriptStore)
        tm.paused = true   // ignore transcripts until the session actually starts

        sttc.onTranscript = { [weak tm, weak self] t in
            if !t.text.isEmpty { self?.inactivity.noteActivity() } // interviewer was heard
            DispatchQueue.main.async { tm?.handleTranscript(t) }
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
        sttc.onError = { [weak self] err in
            NSLog("[stt] error: %@", String(describing: err))
            // Only terminal on-device errors (auth denied / no ja model) surface to the user;
            // Deepgram's transient socket errors auto-retry and stay log-only (no error-flashing).
            guard err is SttError else { return }
            DispatchQueue.main.async {
                guard let self else { return }
                self.notch.model.status = .error
                self.notch.model.message = .sttError
                self.notch.model.errorDetail = err.localizedDescription
            }
        }

        let capture = AudioCaptureFactory.make()
        capture.onPCM = { [weak sttc] pcm in sttc?.write(pcm) }
        // Faithful §4 T0: use the audio path's last-voiced time (≈ last phoneme).
        tm.latency.voicedClock = { [weak capture] in capture?.lastVoicedUptimeNs ?? 0 }

        self.turn = tm
        self.stt = sttc
        self.audio = capture
        enterReady()
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
            model.intentLabel = "長文回答"; model.answer = Array(repeating: answer, count: 3).joined()
        case "error":
            model.recording = true; model.status = .error; model.message = .generationError
            model.errorDetail = "接続を確認してください。"
        default:
            model.recording = false; model.status = .ready; model.message = .ready
        }
        if ["thinking", "streaming", "presenting", "overflow", "error"].contains(fixture) {
            model.question = "学生時代に力を入れたことを教えてください。"
        }
    }
}
