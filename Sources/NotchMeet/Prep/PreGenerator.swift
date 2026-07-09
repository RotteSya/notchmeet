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

    /// Generate the bank. `progress` is called on completion of each intent.
    func generate(progress: ((Int, Int) -> Void)? = nil) async {
        let intents = Intents.list
        let context = facts.context(for: "")
        let cli = bestCLI()
        var out: [BankEntry] = []

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

        bank.replaceAll(out)
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
