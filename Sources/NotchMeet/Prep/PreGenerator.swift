import Foundation

/// OFFLINE answer-bank builder (PLAN §8 / §12 Phase 2). For each canonical intent,
/// generate a pre-polished keigo answer grounded in the user's facts, using the best
/// available engine (local CLI for "free" top-model quality, else FastLLM API), then
/// store to the AnswerBank for the Router to serve at near-zero latency.
final class PreGenerator {
    private let facts: FactStore
    private let bank: AnswerBank

    init(facts: FactStore, bank: AnswerBank) {
        self.facts = facts
        self.bank = bank
    }

    /// 每个 intent 一次受管 LLM 调用，按 10 秒额度计（本地 CLI 路径不计量）。
    static let chargeSecondsPerIntent = 10

    /// 预生成实际会用哪个引擎。
    ///
    /// 本机 CLI 与「当前回答模型」显示的那个服务**不是同一个收件人**：它把简历要点
    /// 送进用户自己的 Anthropic / OpenAI 账号。此前这条路径被静默优先使用，而所有
    /// 披露文案（同意书、隐私页、README）列出的收件人里从来没有它——用户配置了
    /// DeepSeek、界面也显示 DeepSeek，数据却走了别处。
    ///
    /// 所以解析结果必须能被 UI 拿到：按钮旁在**按下之前**就写出真实引擎与代价，
    /// 这与 `consentBody(sttLocal:)` 点名真实 STT 收件人是同一条原则。
    enum PrepEngine: Equatable {
        /// 本机安装的 agent CLI（走用户自己的账号，不消耗本应用额度）。
        case localCLI(name: String, path: String)
        /// 受管 / 自备 Key 的云端服务，与「当前回答模型」一致（按额度计量）。
        case managed(String)
        /// 两条路都没有——按钮该置灰，而不是先扣额度再失败 19 次。
        case unavailable

        /// 供应商真名，用于披露文案：用户账号在谁那里。
        var vendor: String? {
            switch self {
            case .localCLI("claude", _): "Anthropic"
            case .localCLI("codex", _):  "OpenAI"
            case .localCLI:              nil
            case .managed, .unavailable: nil
            }
        }
    }

    /// 本机装了哪个 agent CLI——**不看** `useLocalCliForPrep` 开关。
    /// 用于「要不要显示那个开关」和「隐私页要不要提这条收件人」：装了但关掉了，
    /// 开关仍要在，否则用户没有再打开它的入口。
    static func installedCLI() -> (name: String, vendor: String)? {
        let detected = CliRunner.detect()
        for name in ["claude", "codex"] where detected[name]?.installed == true {
            let engine = PrepEngine.localCLI(name: name, path: "")
            return (name, engine.vendor ?? name)
        }
        return nil
    }

    static func resolveEngine() -> PrepEngine {
        if Settings.useLocalCliForPrep {
            let detected = CliRunner.detect()
            if let c = detected["claude"], c.installed, let p = c.path {
                return .localCLI(name: "claude", path: p)
            }
            if let c = detected["codex"], c.installed, let p = c.path {
                return .localCLI(name: "codex", path: p)
            }
        }
        if let name = ProviderRegistry.llmDisplayName() { return .managed(name) }
        return .unavailable
    }

    /// 送进预生成 prompt 的简历事实——与实时生成（TurnManager）、原稿整形（ScriptImporter）
    /// 同一道隐私门。用户在「隐私与数据」关掉「把简历要点与原稿发送给 AI」之后，这条路径
    /// 也不能把简历送出去；关掉时照常预生成，只是回答更通用。
    ///
    /// 此前这里无条件读 facts。当时没有 facts 写入口、事实恒为空，所以漏不出东西；
    /// 简历事实编辑器上线后，它就变成一条真实的泄漏路径了。
    static func groundingContext(_ facts: FactStore) -> String {
        Settings.sendContextToLLM ? facts.context(for: "") : ""
    }

    /// Generate the bank. `progress` is called on completion of each intent.
    func generate(progress: ((Int, Int) -> Void)? = nil) async {
        let language = Settings.interviewLanguage
        let intents = Intents.list(for: language)
        let context = Self.groundingContext(facts)
        let engine = Self.resolveEngine()
        var out: [BankEntry] = []

        // 两条路都不可用时直接退出：旧实现会先扣满额度，再眼睁睁看 19 个 intent
        // 全部失败——为一次注定失败的预生成付钱。
        guard engine != .unavailable else {
            NSLog("[prep] no engine available (no local CLI, no LLM key) — skipping")
            return
        }
        // 受管路径按次计量；本机 CLI 走用户自己的账号，不计量。
        if case .managed = engine,
           !CreditManager.shared.chargeOneShot(
               seconds: Self.chargeSecondsPerIntent * intents.count) {
            NSLog("[prep] insufficient credit — skipping answer bank build")
            return
        }
        NSLog("[prep] engine = %@", String(describing: engine))

        for (i, intent) in intents.enumerated() {
            let prompt = buildPrompt(intent: intent, context: context, language: language)
            let answer: String
            do {
                switch engine {
                case .localCLI(let name, let path):
                    answer = try await CliRunner.run(cli: name, binPath: path, prompt: prompt)
                case .managed, .unavailable:
                    let user: String
                    switch language {
                    case .japanese:
                        user = "質問: \(intent)\n\nそのまま声に出して答えられる完成した回答文だけを出力してください。"
                    case .chinese:
                        user = "问题: \(intent)\n\n请只输出可以直接照着说出口的完整回答正文。"
                    }
                    answer = try await FastLLM.complete(
                        system: Prompts.system(context: context, language: language),
                        user: user,
                        maxTokens: 400)
                }
                let spoken = SpokenAnswerFormatter.normalize(answer)
                if !spoken.isEmpty {
                    out.append(BankEntry(id: intent, intent: intent, question: intent,
                                         answer: spoken, locked: false, format: .spoken))
                }
            } catch {
                NSLog("[prep] %@ failed: %@", intent, String(describing: error))
            }
            progress?(i + 1, intents.count)
        }

        // 全部 intent 都失败（断网/限流）时，绝不用空表覆盖既有答案库——
        // 面试前点一次「预生成」就把可用的旧答案清空，是最坏的时机。
        guard !out.isEmpty else {
            NSLog("[prep] all %d intents failed — keeping existing answer bank", intents.count)
            return
        }
        await bank.replaceAll(out)   // 主线程写：与 TurnManager 的读同域
        // 语言戳与库内容同步落盘：路由取候选时与本场面试语言比对，不一致整库跳过
        // ——日语库的答案在中文面试里被逐字上屏是最糟的串场（BankEntry 本身没有
        // 语言字段，库是整体重建的，戳在库粒度上即可）。
        Settings.answerBankLanguage = language
        NSLog("[prep] answer bank built: %d/%d intents (%@)", out.count, intents.count,
              language.rawValue)
    }

    private func buildPrompt(intent: String, context: String,
                             language: InterviewLanguage) -> String {
        switch language {
        case .chinese:
            return """
            \(Prompts.system(context: context, language: language))

            # 面试官的问题
            \(intent)

            请只以上述事实信息为依据，写出可以直接照着说出口的自然回答。
            只输出 2〜5 句连续的口语正文，不使用条目、编号、标题或 Markdown。
            """
        case .japanese:
            return """
            \(Prompts.system(context: context, language: language))

            # 面接官の質問
            \(intent)

            上記の事実情報だけを根拠に、そのまま声に出して答えられる自然な回答文を作成してください。
            2〜5文の連続した話し言葉だけを出力し、箇条書き・番号・見出し・Markdownは使用しないでください。
            """
        }
    }
}
