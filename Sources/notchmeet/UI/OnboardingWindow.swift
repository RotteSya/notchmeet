import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// First-launch onboarding. Five steps — welcome → import script → system-audio
/// permission → live demo → done. Hosted in an NSWindow like `PrepWindowController`:
/// the app is an accessory (LSUIElement) with no Dock icon, so it can't take key focus
/// as-is — flip to `.regular` while open, restore on close. The backdrop is a live Metal
/// aurora (`AuroraBackground`); the demo drives the REAL notch and permission hits real TCC.
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let previousPolicy: NSApplication.ActivationPolicy

    /// Provide the user's already-saved script (markdown) to preload the editor + demo.
    var loadScript: (() -> String)?
    /// Parse + persist the script, returning how many entries were recognized.
    var onSaveScript: ((String) -> Int)?
    /// Trigger the real macOS audio-capture permission prompt; reports whether it was granted.
    var onRequestPermission: ((@escaping (Bool) -> Void) -> Void)?
    /// Whether an API key (Keychain or env) is already present — seeds the key step's ✓ state.
    var keyPresent: ((String) -> Bool)?
    /// Persist (or clear, when empty) an API key to the Keychain. Going live is deferred to
    /// `onFinish` so no audio tap starts mid-onboarding.
    var onSaveKey: ((_ name: String, _ value: String) -> Void)?
    /// Play the demo on the real notch: stream `answer` under the `intent` tag, and speak
    /// the interviewer's question aloud (`spokenJa`, always Japanese).
    var onPlayDemo: ((_ answer: String, _ intent: String, _ spokenJa: String) -> Void)?
    /// Onboarding finished (or window closed): (permissionGranted, recognizedCount).
    var onFinish: ((Bool, Int) -> Void)?

    override init() {
        self.previousPolicy = NSApp.activationPolicy()
        super.init()
    }

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let view = OnboardingView(
            initialScript: loadScript?() ?? "",
            saveScript: { [weak self] in self?.onSaveScript?($0) ?? 0 },
            requestPermission: { [weak self] cb in self?.onRequestPermission?(cb) },
            keyPresent: { [weak self] name in self?.keyPresent?(name) ?? false },
            saveKey: { [weak self] name, value in self?.onSaveKey?(name, value) },
            playDemo: { [weak self] answer, intent, spokenJa in self?.onPlayDemo?(answer, intent, spokenJa) },
            finish: { [weak self] granted, count in
                // Bind `self` strongly for the whole closure: `onFinish` drops AppController's
                // only strong ref to this controller (`onboarding = nil`), which would otherwise
                // deallocate us mid-closure and silently skip `window.close()` — the "button
                // does nothing" bug. The strong binding keeps us alive through the close (and
                // its `windowWillClose`, which restores the activation policy).
                guard let self else { return }
                self.onFinish?(granted, count)
                self.window?.close()
            }
        )
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 588, height: 708),
                         styleMask: [.titled, .fullSizeContentView, .closable],
                         backing: .buffered, defer: false)
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.isMovableByWindowBackground = true
        w.backgroundColor = NSColor(red: 0.024, green: 0.027, blue: 0.043, alpha: 1) // #06070b
        w.appearance = NSAppearance(named: .darkAqua)
        let hosting = NSHostingView(rootView: view)
        hosting.sizingOptions = []          // SwiftUI content must NOT drive the window size
        hosting.layer?.backgroundColor = .clear
        w.contentView = hosting
        w.center()
        w.isReleasedWhenClosed = false
        w.delegate = self
        self.window = w

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(previousPolicy)
        window = nil
    }
}

// MARK: - Localized copy (中 / 日), ported verbatim from the design

struct OBStrings {
    let welcomeT1, welcomeT2, welcomeP, welcomeBtn, welcomeFoot: String
    let k1, h1step, p1pre, p1em, p1post, lblScript, btnPickMd, btnSample, phScript, dropHint: String
    let recogPre, recogSuf: String
    let btnBack, btnSkip, btnNext: String
    let k2, h2step, p2, permLabel, permSet, permDesc, privacy, btnAllow: String
    let k3, h3step, p3pre, p3em, p3post, srcLabel, captionIdle, btnAgain: String
    let doneH, doneP, sumScriptLabel, sumPermLabel, sumLanguageLabel, sumLanguageValue, btnStart, doneFoot: String
    let demoQuestion, demoAnswer, intentTag, demoQFormat, verbatim: String
    let unitCount, skipped, permUnset: String
    // STEP 3 — connect services (API keys), and the readiness-aware「done」state.
    let kKeys, hKeys, pKeys, keyDeepgramLabel, keyLLMLabel: String
    let keyDeepgramPh, keyLLMPh, keyDeepgramHelp, keyLLMHelp, keyReplacePh: String
    let keyRequired, keyConnected, keyMissing, keyPrivacy, doneHpending: String
    let donePpending, sumDeepgramLabel, sumLLMLabel, btnFix, btnEnterAnyway: String

    static func of(_ lang: UILanguage) -> OBStrings { lang == .ja ? ja : zh }

    static let zh = OBStrings(
        welcomeT1: "面试中，刘海", welcomeT2: "化作你的语言。",
        welcomeP: "实时聆听面试官的声音，将贴合你原稿与经历的回答，悄然映现在屏幕顶部的刘海上。",
        welcomeBtn: "开始", welcomeFoot: "约需 1 分钟・稍后可在设置中更改",
        k1: "STEP 1 · 面试原稿", h1step: "导入你准备好的回答",
        p1pre: "请导入日语回答。匹配到问题后，会", p1em: "原样", p1post: "呈现你的日语原稿。",
        lblScript: "原稿", btnPickMd: "选择 .md", btnSample: "示例",
        phScript: "# 自己紹介\n〇〇大学△△学部の□□と申します……\n\n# 志望動機\n貴社の「ユーザー第一」という姿勢に強く共感しています……",
        dropHint: "拖放到此处导入",
        recogPre: "已识别 ", recogSuf: " 个问题",
        btnBack: "返回", btnSkip: "跳过", btnNext: "下一步",
        k2: "STEP 2 · 访问权限", h2step: "聆听面试官的声音",
        p2: "录音期间，只捕获你所选通话 App 播放的声音（不使用麦克风）。",
        permLabel: "录制系统音频", permSet: "已允许",
        permDesc: "仅捕获你指定的通话 App 的输出音频，不触及麦克风、摄像头或屏幕。",
        privacy: "为识别问题并生成回答，录音会上传 Deepgram 转写，问题与你的简历／原稿会发送给所选 AI（Gemini／Claude）。仅 API Key 保存在本机。",
        btnAllow: "允许访问",
        k3: "STEP 4 · 演示", h3step: "聆听日语，使用日语作答",
        p3pre: "播放日语问题后，可直接照念的完整日语回答会显示在", p3em: "屏幕顶部的刘海", p3post: "上。",
        srcLabel: "面试官 · 日语", captionIdle: "「志望動機について教えてください。」",
        btnAgain: "再播放一次",
        doneH: "准备就绪", doneP: "操作界面使用中文，日语面试问题与日语回答会显示在刘海中。",
        sumScriptLabel: "面试原稿", sumPermLabel: "录制系统音频",
        sumLanguageLabel: "语言", sumLanguageValue: "界面：中文 · 面试与回答：日语",
        btnStart: "开始使用 NotchMeet", doneFoot: "提示：⌘⇧Space 可切换显示／隐藏",
        demoQuestion: "志望動機について教えてください。",
        demoAnswer: "私は、貴社の「ユーザー第一」という姿勢に強く共感しています。インターンで培ったデータ分析の経験を活かし、利用者の声を丁寧に捉えながらプロダクト改善に貢献したいと考えています。",
        intentTag: "志望動機", demoQFormat: "%@について教えてください。", verbatim: "日语原稿",
        unitCount: "个", skipped: "已跳过", permUnset: "未设置",
        kKeys: "STEP 3 · 连接服务", hKeys: "连接语音识别与 AI",
        pKeys: "NotchMeet 用你自己的 Key 工作：识别面试官语音用 Deepgram，生成回答用 AI。两者都需要。",
        keyDeepgramLabel: "Deepgram · 语音识别", keyLLMLabel: "AI · 生成回答",
        keyDeepgramPh: "粘贴 Deepgram API Key", keyLLMPh: "粘贴所选服务的 API Key",
        keyDeepgramHelp: "在 deepgram.com 免费注册获取", keyLLMHelp: "Gemini 有免费额度，二选一即可",
        keyReplacePh: "已连接 · 粘贴新 Key 可替换",
        keyRequired: "必填", keyConnected: "已连接", keyMissing: "待设置 · 必填",
        keyPrivacy: "Key 仅存于本机钥匙串，绝不上传服务器。",
        doneHpending: "还差最后一步", donePpending: "完成下面标记「待设置」的项目，就能开始使用。",
        sumDeepgramLabel: "语音识别 · Deepgram", sumLLMLabel: "回答生成 · AI",
        btnFix: "去补齐设置", btnEnterAnyway: "仍然进入"
    )

    static let ja = OBStrings(
        welcomeT1: "面接中、ノッチが", welcomeT2: "あなたの言葉になる。",
        welcomeP: "面接官の声をリアルタイムで聞き取り、あなたの原稿と経歴に沿った答えを、画面上部のノッチにそっと映し出します。",
        welcomeBtn: "はじめる", welcomeFoot: "所要時間 約1分・あとから設定で変更できます",
        k1: "STEP 1 / 面接原稿", h1step: "用意した答えを読み込む",
        p1pre: "見出しで質問を区切った原稿を貼り付けると、一致した質問では原稿を", p1em: "そのまま", p1post: "提示します。",
        lblScript: "原稿", btnPickMd: ".md を選択", btnSample: "サンプル",
        phScript: "# 自己紹介\n〇〇大学△△学部の□□と申します……\n\n# 志望動機\n貴社の「ユーザー第一」という姿勢に……",
        dropHint: "ここにドロップして読み込む",
        recogPre: "", recogSuf: " 件の質問を認識しました",
        btnBack: "戻る", btnSkip: "スキップ", btnNext: "次へ",
        k2: "STEP 2 / アクセス許可", h2step: "面接官の声を聞き取る",
        p2: "録音中、選択した通話アプリから出る音声のみを取得します（マイクは使いません）。",
        permLabel: "システム音声の録音", permSet: "許可済み",
        permDesc: "指定した通話アプリの出力音声のみを取得します。マイク・カメラ・画面には触れません。",
        privacy: "質問の認識と回答生成のため、録音は Deepgram に、質問とあなたの履歴書／原稿は選択した AI（Gemini／Claude）に送信されます。API キーのみ端末内に保存されます。",
        btnAllow: "アクセスを許可",
        k3: "STEP 4 / デモ", h3step: "聞いて、答える。試してみる",
        p3pre: "再生すると面接官の質問が流れます。", p3em: "画面上部のノッチ", p3post: "に、そのまま読める回答文が現れます。",
        srcLabel: "面接官 · Zoom", captionIdle: "「志望動機について教えてください。」",
        btnAgain: "もう一度",
        doneH: "準備が整いました", doneP: "面接が始まったら、通話アプリを開くだけ。ノッチが静かに待機しています。",
        sumScriptLabel: "面接原稿", sumPermLabel: "システム音声の録音",
        sumLanguageLabel: "言語", sumLanguageValue: "画面：日本語・面接と回答：日本語",
        btnStart: "NotchMeet を始める", doneFoot: "ヒント: ⌘⇧Space で表示／非表示を切り替えられます",
        demoQuestion: "志望動機について教えてください。",
        demoAnswer: "私は、貴社の「ユーザー第一」という姿勢に強く共感しています。インターンで培ったデータ分析の経験を活かし、利用者の声を丁寧に捉えながらプロダクト改善に貢献したいと考えています。",
        intentTag: "志望動機", demoQFormat: "%@について教えてください。", verbatim: "原稿どおり",
        unitCount: "件", skipped: "スキップ", permUnset: "未設定",
        kKeys: "STEP 3 / 接続", hKeys: "音声認識と AI に接続",
        pKeys: "NotchMeet はあなたの API キーで動きます。面接官の音声認識に Deepgram、回答生成に AI を使います。どちらも必要です。",
        keyDeepgramLabel: "Deepgram · 音声認識", keyLLMLabel: "AI · 回答生成",
        keyDeepgramPh: "Deepgram API キーを貼り付け", keyLLMPh: "選んだサービスの API キーを貼り付け",
        keyDeepgramHelp: "deepgram.com で無料登録して取得", keyLLMHelp: "Gemini は無料枠あり・どちらか一方でOK",
        keyReplacePh: "接続済み · 新しいキーで置き換え可",
        keyRequired: "必須", keyConnected: "接続済み", keyMissing: "未設定 · 必須",
        keyPrivacy: "キーは端末の Keychain にのみ保存され、送信されません。",
        doneHpending: "あと一歩で完了", donePpending: "下の「未設定」の項目を整えると、すぐに使えます。",
        sumDeepgramLabel: "音声認識 · Deepgram", sumLLMLabel: "回答生成 · AI",
        btnFix: "設定を完了する", btnEnterAnyway: "そのまま開始"
    )
}

// MARK: - Step transition (a single, unified motion for the whole flow)

private struct OBBlur: ViewModifier {
    var radius: CGFloat
    func body(content: Content) -> some View { content.blur(radius: radius) }
}
private extension AnyTransition {
    static func obBlur(_ r: CGFloat) -> AnyTransition {
        .modifier(active: OBBlur(radius: r), identity: OBBlur(radius: 0))
    }
    static var obStep: AnyTransition {
        .asymmetric(
            insertion: .opacity.combined(with: .offset(y: 14)).combined(with: .obBlur(8)),
            removal: .opacity.combined(with: .scale(scale: 0.985)).combined(with: .obBlur(6))
        )
    }
}

// MARK: - Root view

struct OnboardingView: View {
    /// The user's already-saved script (markdown), preloaded so the editor AND the step-3
    /// demo reflect it — even when onboarding is reopened or the script was imported in a
    /// prior session. Empty when there is none (the demo then falls back to the sample).
    let initialScript: String
    let saveScript: (String) -> Int
    let requestPermission: (@escaping (Bool) -> Void) -> Void
    /// Whether an API key is already present (Keychain or env), used to seed ✓ state.
    let keyPresent: (String) -> Bool
    /// Persist (or clear) an API key. Empty value clears it.
    let saveKey: (_ name: String, _ value: String) -> Void
    let playDemo: (_ answer: String, _ intent: String, _ spokenJa: String) -> Void
    let finish: (Bool, Int) -> Void

    @ObservedObject private var languageStore = AppLanguageStore.shared
    @State private var step = 0
    @State private var scriptText = ""
    @State private var permAttempted = false
    @State private var permGranted = false
    @State private var deepgramKey = ""        // newly entered this session (empty = leave as-is)
    @State private var llmKey = ""
    @State private var deepgramSet = false      // seeded from `keyPresent`, flipped on commit
    @State private var llmSet = false
    @State private var llmName = "GEMINI_API_KEY"   // which provider a newly pasted LLM key targets
    @State private var demoPlayed = false
    @State private var demoPlaying = false
    @State private var demoResetWork: DispatchWorkItem?
    @Namespace private var langNS

    private let total = 6
    private var lang: UILanguage { languageStore.language }
    private var t: OBStrings { .of(languageStore.language) }
    private var recognized: [BankEntry] { ScriptParser.parse(scriptText) }

    /// Each required service has a usable key: either one was already present (seeded from
    /// `keyPresent`) or the user just typed one (committed on Next/finish).
    private var deepgramSatisfied: Bool {
        deepgramSet || !deepgramKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    private var llmSatisfied: Bool {
        llmSet || !llmKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    /// The app can only actually work with audio permission AND both keys — the SAME predicate
    /// the live pipeline gates on (`Settings.apiKey`). Gating「准备就绪」on this is what makes
    /// the terminal state honest instead of an unconditional celebration.
    private var allReady: Bool { permGranted && deepgramSatisfied && llmSatisfied }

    /// The script entry the demo plays back, so the notch shows the user's OWN verbatim
    /// answer. Prefer the motivation question — it lines up with the default copy — else
    /// the first entry; nil if nothing was imported (demo falls back to the localized sample).
    private var demoEntry: BankEntry? {
        let keys = ["志望", "動機", "动机", "应聘", "応募", "motiv"]
        let preferred = recognized.first { e in keys.contains { e.question.lowercased().contains($0) } }
        let candidate = preferred ?? recognized.first
        guard let candidate, containsJapaneseKana(candidate.question + candidate.answer) else { return nil }
        return candidate
    }
    private var demoCaption: String {
        "「\(spokenQuestionJa)」"
    }
    /// What the interviewer SAYS OUT LOUD — always Japanese, independent of the UI language
    /// (a 就活 interviewer speaks Japanese even when the user is reading the 中 UI).
    private var spokenQuestionJa: String {
        if let e = demoEntry { return String(format: OBStrings.ja.demoQFormat, e.question) }
        return OBStrings.ja.demoQuestion
    }

    private func containsJapaneseKana(_ text: String) -> Bool {
        text.unicodeScalars.contains {
            (0x3040...0x30ff).contains(Int($0.value))
        }
    }

    var body: some View {
        ZStack {
            AuroraBackground(progress: Double(step) / Double(total - 1))
                .ignoresSafeArea()

            VStack(spacing: 18) {
                header
                ZStack {
                    stepContent
                        .id(step)
                        .transition(.obStep)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(28)
            .frame(width: 484, height: 556)
            .obSurface(cornerRadius: 24, fill: 0.30, elevated: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(OB.spring, value: step)
        .onAppear {
            if scriptText.isEmpty { scriptText = initialScript }
            deepgramSet = keyPresent("DEEPGRAM_API_KEY")
            llmSet = keyPresent("GEMINI_API_KEY") || keyPresent("ANTHROPIC_API_KEY")
        }
    }

    @ViewBuilder private var stepContent: some View {
        switch step {
        case 0: welcomeStep
        case 1: importStep
        case 2: permissionStep
        case 3: keysStep
        case 4: demoStep
        default: doneStep
        }
    }

    // MARK: header — progress rail + step label + lang toggle

    private var header: some View {
        HStack(spacing: 10) {
            OBProgressRail(step: step, total: total)
            Spacer(minLength: 8)
            Text("\(step + 1) / \(total)")
                .font(.system(size: 11)).monospacedDigit()
                .foregroundStyle(OB.ink.opacity(0.32))
            langToggle
        }
        .frame(height: 22)
    }

    private var langToggle: some View {
        HStack(spacing: 2) {
            langButton("中", .zh)
            langButton("日", .ja)
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.black.opacity(0.30))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5))
        )
    }

    private func langButton(_ label: String, _ l: UILanguage) -> some View {
        let on = lang == l
        return Button {
            withAnimation(OB.springSnappy) { languageStore.language = l }
        } label: {
            Text(label)
                .font(.system(size: 11.5, weight: on ? .semibold : .medium))
                .frame(width: 24, height: 20)
                .foregroundStyle(on ? OB.inkDeep : OB.ink.opacity(0.55))
                .background {
                    if on {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(LinearGradient(colors: [OB.accentHi, OB.accent], startPoint: .top, endPoint: .bottom))
                            .matchedGeometryEffect(id: "langpill", in: langNS)
                    }
                }
        }
        .buttonStyle(.plain)
    }

    // MARK: step 0 — welcome

    private var welcomeStep: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            OBHeroIcon(size: 92, variant: .welcome).padding(.bottom, 18)
            Text("\(t.welcomeT1)\n\(t.welcomeT2)")
                .font(.system(size: 28, weight: .semibold))
                .tracking(0.3)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
            Text(t.welcomeP)
                .font(.system(size: 13)).lineSpacing(4)
                .multilineTextAlignment(.center)
                .lineLimit(2).minimumScaleFactor(0.9)   // keep it to two balanced lines — no lone-character orphan
                .foregroundStyle(OB.ink.opacity(0.58))
                .frame(maxWidth: 346)
                .padding(.top, 14)
            OBPrimaryButton(t.welcomeBtn, minWidth: 120) { next() }.padding(.top, 28)
            Text(t.welcomeFoot)
                .font(.system(size: 11)).foregroundStyle(OB.ink.opacity(0.3))
                .padding(.top, 14)
            Spacer(minLength: 0)
        }
    }

    // MARK: step 1 — import script

    private var importStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            OBKicker(text: t.k1)
            Text(t.h1step).font(.system(size: 21, weight: .semibold)).foregroundStyle(.white).padding(.top, 12)
            (Text(t.p1pre).foregroundStyle(OB.ink.opacity(0.54))
                + Text(t.p1em).foregroundStyle(OB.ink.opacity(0.9)).font(.system(size: 12.5, weight: .semibold))
                + Text(t.p1post).foregroundStyle(OB.ink.opacity(0.54)))
                .font(.system(size: 12.5)).lineSpacing(2).padding(.top, 7)

            HStack {
                Text(t.lblScript).font(.system(size: 11)).tracking(0.8).foregroundStyle(OB.ink.opacity(0.4))
                Spacer()
                OBTextButton(t.btnPickMd, systemImage: "arrow.up.doc", tint: OB.accent) { pickFile() }
                OBTextButton(t.btnSample, systemImage: "plus") { withAnimation(OB.spring) { scriptText = OnboardingView.sampleScript } }
            }
            .padding(.top, 16).padding(.bottom, 7)

            ScriptEditor(text: $scriptText, placeholder: t.phScript, dropHint: t.dropHint)
                .frame(height: 82)

            if !recognized.isEmpty {
                HStack(spacing: 7) {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 12)).foregroundStyle(OB.accent)
                    Text("\(t.recogPre)\(recognized.count)\(t.recogSuf)")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(OB.accent)
                }.padding(.top, 13)

                VStack(spacing: 0) {
                    ForEach(Array(recognized.prefix(3).enumerated()), id: \.offset) { idx, q in
                        HStack(spacing: 10) {
                            Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)).foregroundStyle(OB.accent)
                                .frame(width: 18, height: 18)
                                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(OB.accent.opacity(0.16)))
                            Text(q.question).font(.system(size: 12.5, weight: .medium)).foregroundStyle(OB.ink.opacity(0.92)).lineLimit(1)
                            Text(excerpt(q.answer)).font(.system(size: 11.5)).foregroundStyle(OB.ink.opacity(0.36)).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 13).padding(.vertical, 8.5)
                        if idx < min(3, recognized.count) - 1 { Divider().overlay(Color.white.opacity(0.05)) }
                    }
                    if recognized.count > 3 {
                        Divider().overlay(Color.white.opacity(0.05))
                        HStack {
                            Text("＋\(recognized.count - 3)\(t.unitCount)")
                                .font(.system(size: 11.5)).foregroundStyle(OB.ink.opacity(0.4))
                            Spacer()
                        }.padding(.horizontal, 13).padding(.vertical, 8)
                    }
                }
                .obSurface(cornerRadius: 12, fill: 0.18)
                .padding(.top, 10)
                .transition(.opacity.combined(with: .offset(y: 8)))
            }

            Spacer(minLength: 12)
            navBar {
                OBTextButton(t.btnSkip) { withAnimation(OB.spring) { scriptText = ""; next() } }
                OBPrimaryButton(t.btnNext) { commitScript(); next() }
            }
        }
        .animation(OB.spring, value: recognized.count)
    }

    // MARK: step 2 — permission

    private var permissionStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            OBKicker(text: t.k2)
            Text(t.h2step).font(.system(size: 21, weight: .semibold)).foregroundStyle(.white).padding(.top, 12)
            Text(t.p2).font(.system(size: 12.5)).lineSpacing(3).foregroundStyle(OB.ink.opacity(0.54)).padding(.top, 8)

            HStack(alignment: .top, spacing: 13) {
                ZStack {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(OB.accent.opacity(permGranted ? 0.22 : 0.14))
                        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(OB.accent.opacity(permGranted ? 0.5 : 0.28), lineWidth: 0.75))
                        .frame(width: 40, height: 40)
                    Image(systemName: permGranted ? "checkmark" : "waveform")
                        .font(.system(size: 17, weight: permGranted ? .bold : .regular))
                        .foregroundStyle(OB.accent)
                        .contentTransition(.symbolEffect(.replace))
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(t.permLabel).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(.white)
                        if permGranted {
                            Text(t.permSet)
                                .font(.system(size: 10.5, weight: .semibold)).foregroundStyle(OB.accent)
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .background(Capsule().fill(OB.accent.opacity(0.16)))
                                .transition(.scale.combined(with: .opacity))
                        }
                    }
                    Text(t.permDesc).font(.system(size: 11.5)).lineSpacing(2).foregroundStyle(OB.ink.opacity(0.52))
                }
                Spacer(minLength: 0)
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(permGranted ? OB.accent.opacity(0.08) : Color.black.opacity(0.22))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(permGranted ? OB.accent.opacity(0.4) : Color.white.opacity(0.1), lineWidth: 0.75))
            )
            .padding(.top, 18)
            .animation(OB.spring, value: permGranted)

            HStack(spacing: 9) {
                Image(systemName: "lock.shield.fill").font(.system(size: 13)).foregroundStyle(OB.ink.opacity(0.42))
                Text(t.privacy).font(.system(size: 11.5)).lineSpacing(1).foregroundStyle(OB.ink.opacity(0.44))
            }.padding(.top, 16)

            Spacer(minLength: 12)
            navBar {
                if permAttempted { OBPrimaryButton(t.btnNext) { next() } }
                else { OBPrimaryButton(t.btnAllow) { grant() } }
            }
        }
    }

    // MARK: step 3 — connect services (Deepgram STT + an LLM key)

    /// The app cannot transcribe without a Deepgram key, nor answer without an LLM key
    /// (see `ProviderRegistry` / `AppController.reloadPipeline`). Collecting them here is
    /// what lets the「done」step honestly say「准备就绪」instead of promising a setup-free start.
    private var keysStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            OBKicker(text: t.kKeys)
            Text(t.hKeys).font(.system(size: 21, weight: .semibold)).foregroundStyle(.white).padding(.top, 12)
            Text(t.pKeys).font(.system(size: 12.5)).lineSpacing(3).foregroundStyle(OB.ink.opacity(0.54)).padding(.top, 8)

            VStack(spacing: 11) {
                keyRow(label: t.keyDeepgramLabel, set: deepgramSet, field: $deepgramKey,
                       placeholder: t.keyDeepgramPh, helper: t.keyDeepgramHelp) { EmptyView() }
                keyRow(label: t.keyLLMLabel, set: llmSet, field: $llmKey,
                       placeholder: t.keyLLMPh, helper: t.keyLLMHelp) { llmPicker }
            }
            .padding(.top, 16)

            HStack(spacing: 9) {
                Image(systemName: "lock.shield.fill").font(.system(size: 13)).foregroundStyle(OB.ink.opacity(0.42))
                Text(t.keyPrivacy).font(.system(size: 11.5)).lineSpacing(1).foregroundStyle(OB.ink.opacity(0.44))
            }.padding(.top, 14)

            Spacer(minLength: 12)
            navBar {
                OBTextButton(t.btnSkip) { next() }
                OBPrimaryButton(t.btnNext) { commitKeys(); next() }
            }
        }
    }

    /// One labeled secure field with a ✓ badge once a key is present (Keychain or just typed).
    /// `accessory` carries the LLM provider toggle; Deepgram passes an `EmptyView`.
    @ViewBuilder
    private func keyRow<Accessory: View>(label: String, set: Bool, field: Binding<String>,
                                         placeholder: String, helper: String,
                                         @ViewBuilder accessory: () -> Accessory) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(label).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                if set { keyBadge(t.keyConnected, filled: true) }
                else { keyBadge(t.keyRequired, filled: false) }
                Spacer(minLength: 0)
                accessory()
            }
            SecureField(set ? t.keyReplacePh : placeholder, text: field)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(OB.ink.opacity(0.92))
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black.opacity(0.30))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.75))
                )
            Text(helper).font(.system(size: 10.5)).foregroundStyle(OB.ink.opacity(0.40))
        }
        .padding(13)
        .obSurface(cornerRadius: 14, fill: 0.18)
    }

    private func keyBadge(_ text: String, filled: Bool) -> some View {
        Text(text)
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(filled ? OB.accent : OB.ink.opacity(0.5))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(filled ? OB.accent.opacity(0.16) : Color.white.opacity(0.06)))
    }

    /// Picks which provider a newly pasted LLM key is saved under (the pipeline accepts either).
    private var llmPicker: some View {
        HStack(spacing: 2) {
            llmPickerPill("Gemini", "GEMINI_API_KEY")
            llmPickerPill("Claude", "ANTHROPIC_API_KEY")
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.black.opacity(0.30)))
    }

    private func llmPickerPill(_ label: String, _ name: String) -> some View {
        let on = llmName == name
        return Button { withAnimation(OB.springSnappy) { llmName = name } } label: {
            Text(label)
                .font(.system(size: 10.5, weight: on ? .semibold : .medium))
                .foregroundStyle(on ? OB.inkDeep : OB.ink.opacity(0.6))
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background { if on { RoundedRectangle(cornerRadius: 6, style: .continuous).fill(OB.accent) } }
        }
        .buttonStyle(.plain)
    }

    // MARK: step 4 — demo (drives the REAL notch)

    private var demoStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            OBKicker(text: t.k3)
            Text(t.h3step).font(.system(size: 21, weight: .semibold)).foregroundStyle(.white).padding(.top, 12)
            (Text(t.p3pre).foregroundStyle(OB.ink.opacity(0.54))
                + Text(t.p3em).foregroundStyle(OB.accent).font(.system(size: 12.5, weight: .semibold))
                + Text(t.p3post).foregroundStyle(OB.ink.opacity(0.54)))
                .font(.system(size: 12.5)).lineSpacing(3).padding(.top, 8)

            VStack(spacing: 14) {
                HStack(spacing: 12) {
                    playButton
                    VStack(alignment: .leading, spacing: 3) {
                        Text(t.srcLabel).font(.system(size: 10)).tracking(0.8).foregroundStyle(OB.ink.opacity(0.42))
                        HStack(spacing: 6) {
                            Text(demoCaption).font(.system(size: 13)).foregroundStyle(OB.ink.opacity(0.92)).lineLimit(1)
                            if demoEntry != nil {
                                Text(t.verbatim)
                                    .font(.system(size: 9.5, weight: .semibold)).foregroundStyle(OB.accent)
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Capsule().fill(OB.accent.opacity(0.16))
                                        .overlay(Capsule().strokeBorder(OB.accent.opacity(0.32), lineWidth: 0.5)))
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
                OBWaveform(active: demoPlaying).frame(height: 30)
            }
            .padding(16)
            .obSurface(cornerRadius: 14, fill: 0.24)
            .padding(.top, 16)

            Spacer(minLength: 12)
            navBar {
                if demoPlayed { OBTextButton(t.btnAgain, systemImage: "arrow.clockwise") { runDemo() } }
                if demoPlayed { OBPrimaryButton(t.btnNext) { next() } }
                else { OBGhostButton(t.btnNext) { next() } }
            }
        }
    }

    private var playButton: some View {
        Button(action: runDemo) {
            Image(systemName: "play.fill").font(.system(size: 13)).foregroundStyle(.white)
                .frame(width: 42, height: 42)
                .background(
                    Circle().fill(LinearGradient(colors: [OB.accentHi, OB.accentLo], startPoint: .top, endPoint: .bottom))
                        .overlay(Circle().strokeBorder(.white.opacity(0.35), lineWidth: 0.75))
                )
                .shadow(color: OB.accentLo.opacity(0.5), radius: 10, y: 5)
        }
        .buttonStyle(OBPressScale())
    }

    // MARK: step 5 — done (readiness-aware: never claims ready when it isn't)

    private var doneStep: some View {
        let ready = allReady
        return VStack(spacing: 0) {
            Spacer(minLength: 0)
            // The check-badge hero only appears when actually ready; otherwise the plain mark.
            // Sized down vs. the other steps to make room for the five-row readiness summary.
            OBHeroIcon(size: 64, variant: ready ? .done : .welcome).padding(.bottom, 12)
            Text(ready ? t.doneH : t.doneHpending).font(.system(size: 22, weight: .semibold)).foregroundStyle(.white)
                .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
            Text(ready ? t.doneP : t.donePpending).font(.system(size: 13)).lineSpacing(3).multilineTextAlignment(.center)
                .foregroundStyle(OB.ink.opacity(0.58)).frame(maxWidth: 330).padding(.top, 8)

            VStack(spacing: 0) {
                summaryRow(t.sumScriptLabel, recognized.isEmpty ? t.skipped : "\(recognized.count) \(t.unitCount)", on: !recognized.isEmpty)
                summaryDivider
                summaryRow(t.sumPermLabel, permGranted ? t.permSet : t.permUnset, on: permGranted)
                summaryDivider
                summaryRow(t.sumDeepgramLabel, deepgramSatisfied ? t.keyConnected : t.keyMissing, on: deepgramSatisfied)
                summaryDivider
                summaryRow(t.sumLLMLabel, llmSatisfied ? t.keyConnected : t.keyMissing, on: llmSatisfied)
                summaryDivider
                summaryRow(t.sumLanguageLabel, t.sumLanguageValue, on: true)
            }
            .obSurface(cornerRadius: 12, fill: 0.18)
            .padding(.top, 14).frame(maxWidth: 360)

            if ready {
                OBStartButton(t.btnStart) { commitScript(); commitKeys(); finish(permGranted, recognized.count) }
                    .padding(.top, 14)
                Text(t.doneFoot).font(.system(size: 11)).foregroundStyle(OB.ink.opacity(0.32)).padding(.top, 10)
            } else {
                // Honest terminal: send the user back to the first unmet requirement. Finishing
                // is still allowed (the notch + menu surface the same gap), just not disguised.
                OBPrimaryButton(t.btnFix, minWidth: 150) { goToFirstUnmet() }.padding(.top, 14)
                OBTextButton(t.btnEnterAnyway) { commitScript(); commitKeys(); finish(permGranted, recognized.count) }
                    .padding(.top, 6)
            }
            Spacer(minLength: 0)
        }
    }

    private var summaryDivider: some View { Divider().overlay(Color.white.opacity(0.06)) }

    private func summaryRow(_ label: String, _ value: String, on: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: on ? "checkmark.circle.fill" : "minus.circle")
                .font(.system(size: 13)).foregroundStyle(on ? OB.accent : OB.ink.opacity(0.3))
            Text(label).font(.system(size: 12.5)).foregroundStyle(OB.ink.opacity(0.88))
            Spacer()
            Text(value).font(.system(size: 12, weight: .medium)).foregroundStyle(on ? OB.accent.opacity(0.9) : OB.ink.opacity(0.45))
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
    }

    // MARK: shared bits

    /// A consistent bottom nav: Back on the left, the step's actions trailing.
    private func navBar<Trailing: View>(@ViewBuilder _ trailing: () -> Trailing) -> some View {
        HStack(spacing: 10) {
            OBGhostButton(t.btnBack) { back() }
            Spacer()
            trailing()
        }
    }

    private func excerpt(_ s: String) -> String {
        let one = s.replacingOccurrences(of: "\n", with: " ")
        return one.count > 18 ? String(one.prefix(18)) + "…" : one
    }

    // MARK: actions

    private func next() { withAnimation(OB.spring) { step = min(step + 1, total - 1) } }
    private func back() { withAnimation(OB.spring) { step = max(step - 1, 0) } }

    private func pickFile() {
        let panel = NSOpenPanel()
        var types: [UTType] = [.plainText, .text]
        if let md = UTType(filenameExtension: "md") { types.append(md) }
        if let markdown = UTType(filenameExtension: "markdown") { types.append(markdown) }
        panel.allowedContentTypes = types
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url,
           let s = try? String(contentsOf: url, encoding: .utf8) {
            withAnimation(OB.spring) { scriptText = s }
        }
    }

    private func grant() {
        requestPermission { granted in
            withAnimation(OB.spring) {
                permGranted = granted
                permAttempted = true   // let the user proceed whether or not TCC was granted
            }
        }
    }

    private func runDemo() {
        // The notch streams the user's own imported answer verbatim (or the localized
        // sample if they skipped import); the interviewer's question is spoken aloud in
        // Japanese, keeping the panel caption + notch + audio in sync.
        playDemo(demoEntry?.answer ?? t.demoAnswer, demoEntry?.question ?? t.intentTag, spokenQuestionJa)
        demoPlayed = true
        withAnimation(OB.spring) { demoPlaying = true }
        demoResetWork?.cancel()
        let work = DispatchWorkItem { withAnimation(OB.spring) { demoPlaying = false } }
        demoResetWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.6, execute: work)
    }

    /// Persist the imported script to the shared store. Only writes when something parsed,
    /// so Skip / an empty editor never wipes a script saved in a previous session.
    private func commitScript() {
        if !recognized.isEmpty { _ = saveScript(scriptText) }
    }

    /// Persist any newly typed keys to the Keychain. Only writes non-empty values, so passing
    /// through the step without typing never clears an existing key. Idempotent: called on the
    /// key step's Next and again on finish. Going live happens once, in the controller's finish.
    private func commitKeys() {
        let dg = deepgramKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !dg.isEmpty { saveKey("DEEPGRAM_API_KEY", dg); deepgramSet = true; deepgramKey = "" }
        let lm = llmKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !lm.isEmpty { saveKey(llmName, lm); llmSet = true; llmKey = "" }
    }

    /// From the「还差一步」done state, jump to the first requirement that isn't met.
    private func goToFirstUnmet() {
        withAnimation(OB.spring) { step = permGranted ? 3 : 2 }   // keys step, else permission step
    }

    static let sampleScript = """
    # 自己紹介
    〇〇大学△△学部の□□と申します。学生時代はゼミでデータ分析に取り組み、3人のチームでリーダーを務めました。

    # 志望動機
    貴社の「ユーザー第一」という姿勢に強く共感し志望しました。インターンで培ったデータ分析の経験を活かし、プロダクト改善に貢献したいと考えています。

    # ガクチカ
    ゼミの共同研究で、アンケート500件の分析を担当しました。方針が割れた際は論点を整理して合意形成を進め、学会発表まで漕ぎ着けました。

    # 強み
    課題を構造化して前に進める実行力が強みです。曖昧な状況でも論点を切り分け、優先順位を付けて着手します。

    # 逆質問
    入社後の最初の半年で、特に期待される成果や身につけてほしいスキルがあれば教えていただけますか。
    """
}

// MARK: - Reusable controls local to onboarding

/// A press-scale style for bespoke buttons (the circular play key).
private struct OBPressScale: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(OB.springSnappy, value: configuration.isPressed)
    }
}

/// A smooth, center-weighted voice waveform. Decorative — the real answer streams on the
/// notch above — but it should feel alive: bars swell from the center while "speaking",
/// settle to a calm resting profile otherwise.
private struct OBWaveform: View {
    let active: Bool
    var body: some View {
        TimelineView(.animation) { ctx in
            let phase = ctx.date.timeIntervalSinceReferenceDate
            GeometryReader { geo in
                let n = max(12, Int(geo.size.width / 6))
                HStack(spacing: 3) {
                    ForEach(0..<n, id: \.self) { i in
                        let x = n > 1 ? Double(i) / Double(n - 1) : 0.5
                        let env = sin(x * .pi)                       // center-weighted
                        let amp = active
                            ? 0.16 + 0.84 * env * (0.5 + 0.5 * sin(phase * 5 + Double(i) * 0.55))
                            : (0.14 + 0.20 * env) * (0.85 + 0.15 * sin(Double(i) * 0.7))  // calm resting waveform, not dots
                        Capsule()
                            .fill(LinearGradient(colors: [OB.accent.opacity(active ? 0.95 : 0.32),
                                                          OB.accentLo.opacity(active ? 0.65 : 0.18)],
                                                 startPoint: .top, endPoint: .bottom))
                            .frame(width: 3, height: max(3, geo.size.height * amp))
                            .frame(maxHeight: .infinity)
                    }
                }
                .frame(maxWidth: .infinity)
                .animation(.easeOut(duration: 0.25), value: active)
            }
        }
    }
}

/// A dark, transparent multi-line editor with drag-and-drop of a .md/.txt file and a
/// centered drop hint while a file is hovering.
private struct ScriptEditor: View {
    @Binding var text: String
    let placeholder: String
    let dropHint: String
    @State private var dragging = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text(placeholder)
                    .font(.system(size: 12.5, design: .monospaced))
                    .foregroundStyle(OB.ink.opacity(0.22))
                    .padding(.horizontal, 13).padding(.vertical, 12)
                    .allowsHitTesting(false)
            }
            TextEditor(text: $text)
                .font(.system(size: 12.5, design: .monospaced))
                .foregroundStyle(OB.ink.opacity(0.92))
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 9).padding(.vertical, 6)

            if dragging {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(OB.accent.opacity(0.1))
                    HStack(spacing: 7) {
                        Image(systemName: "arrow.down.doc.fill").font(.system(size: 13)).foregroundStyle(OB.accent)
                        Text(dropHint).font(.system(size: 12, weight: .medium)).foregroundStyle(OB.accent)
                    }
                }
                .allowsHitTesting(false)
                .transition(.opacity)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.black.opacity(0.30))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(dragging ? OB.accent.opacity(0.65) : Color.white.opacity(0.1), lineWidth: dragging ? 1.25 : 0.75))
        )
        .animation(OB.springSnappy, value: dragging)
        .onDrop(of: [.fileURL], isTargeted: $dragging) { providers in
            guard let p = providers.first else { return false }
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                guard let url, let s = try? String(contentsOf: url, encoding: .utf8) else { return }
                DispatchQueue.main.async { withAnimation(OB.spring) { text = s } }
            }
            return true
        }
    }
}
