import AppKit
import SwiftUI
import UniformTypeIdentifiers

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
    @State private var setupCode = ""           // pasted activation code (nmk1.…); empty = leave as-is
    @State private var deepgramSet = false      // seeded from `keyPresent`, flipped on commit
    @State private var llmSet = false
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
    private var deepgramSatisfied: Bool { deepgramSet }
    private var llmSatisfied: Bool { llmSet }
    /// The app can only actually work with audio permission AND both keys — the SAME predicate
    /// the live pipeline gates on (`Settings.apiKey`). Gating「准备就绪」on this is what makes
    /// the terminal state honest instead of an unconditional celebration.
    private var allReady: Bool { permGranted && deepgramSatisfied && llmSatisfied }
    /// 国内网络 + 只有被墙端点（Gemini/Claude）的 Key：就绪总结里显性警告，而不是亮 ✓。
    /// 镜像 live resolver（`ProviderRegistry.llmResolution`）的判断，Key 在到达 done 步前
    /// 已由 `commitKeys()` 落盘，所以 `keyPresent` 反映真实状态。
    private var llmChinaBlocked: Bool {
        Settings.llmBlockedInChina(
            Settings.resolveLLM(hasGemini: keyPresent("GEMINI_API_KEY"),
                                hasClaude: keyPresent("ANTHROPIC_API_KEY"),
                                hasDeepSeek: keyPresent("DEEPSEEK_API_KEY"),
                                hasQwen: keyPresent("DASHSCOPE_API_KEY"),
                                inChina: Settings.isLikelyInChina()),
            inChina: Settings.isLikelyInChina())
    }

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
            llmSet = ["GEMINI_API_KEY", "ANTHROPIC_API_KEY", "DEEPSEEK_API_KEY", "DASHSCOPE_API_KEY"]
                .contains(where: keyPresent)
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
                keyRow(label: t.keyCodeLabel, set: deepgramSet && llmSet, field: $setupCode,
                       placeholder: t.keyCodePh, helper: t.keyCodeHelp) { EmptyView() }
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
                summaryRow(t.sumLLMLabel,
                           llmSatisfied ? (llmChinaBlocked ? t.sumLLMBlocked : t.keyConnected) : t.keyMissing,
                           on: llmSatisfied && !llmChinaBlocked)
                summaryDivider
                summaryRow(t.sumLanguageLabel, t.sumLanguageValue, on: true)
            }
            .obSurface(cornerRadius: 12, fill: 0.18)
            .padding(.top, 14).frame(maxWidth: 360)

            if llmSatisfied && llmChinaBlocked {
                Text(t.llmChinaFoot).font(.system(size: 11)).lineSpacing(2).multilineTextAlignment(.center)
                    .foregroundStyle(.orange.opacity(0.9)).frame(maxWidth: 360).padding(.top, 8)
            }

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
        // Onboarding takes a single activation code (nmk1.…) that carries the Deepgram + LLM key,
        // so a trial user pastes one string instead of obtaining two API keys. BYO users enter raw
        // keys in Settings instead. A non-code paste decodes to nil and is ignored here.
        guard let keys = SetupCode.decode(setupCode) else { return }
        for (name, value) in keys {
            let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !v.isEmpty else { continue }
            saveKey(name, v)
            if name == "DEEPGRAM_API_KEY" { deepgramSet = true } else { llmSet = true }
        }
        setupCode = ""
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
