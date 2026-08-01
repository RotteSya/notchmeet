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
        let intents = Intents.list
        let context = Self.groundingContext(facts)
        let cli = bestCLI()
        var out: [BankEntry] = []

        // 走受管 LLM（无本地 CLI）时按次计量：这条路径此前完全绕过额度系统。
        if cli == nil,
           !CreditManager.shared.chargeOneShot(
               seconds: Self.chargeSecondsPerIntent * intents.count) {
            NSLog("[prep] insufficient credit — skipping answer bank build")
            return
        }

        for (i, intent) in intents.enumerated() {
            let prompt = buildPrompt(intent: intent, context: context)
            let answer: String
            do {
                if let cli {
                    answer = try await CliRunner.run(cli: cli.0, binPath: cli.1, prompt: prompt)
                } else {
                    answer = try await FastLLM.complete(
                        system: Prompts.system(context: context),
                        user: "質問: \(intent)\n\nそのまま声に出して答えられる完成した回答文だけを出力してください。",
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
        NSLog("[prep] answer bank built: %d/%d intents", out.count, intents.count)
    }

    private func bestCLI() -> (String, String)? {
        let det = CliRunner.detect()
        if let c = det["claude"], c.installed, let p = c.path { return ("claude", p) }
        if let c = det["codex"], c.installed, let p = c.path { return ("codex", p) }
        return nil
    }

    private func buildPrompt(intent: String, context: String) -> String {
        """
        \(Prompts.system(context: context))

        # 面接官の質問
        \(intent)

        上記の事実情報だけを根拠に、そのまま声に出して答えられる自然な回答文を作成してください。
        2〜5文の連続した話し言葉だけを出力し、箇条書き・番号・見出し・Markdownは使用しないでください。
        """
    }
}
