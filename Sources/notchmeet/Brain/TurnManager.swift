import Foundation

/// Orchestrates one turn (PLAN §6/§7):
///  - `epoch` = monotonically increasing turn id; every UI write is tagged with its
///    epoch and dropped if stale (= unified cancellation).
///  - Two sources run IN PARALLEL: the router/cache and live generation.
///  - First to produce a usable result COMMITS for the turn (`committedEpoch`); the
///    other is cancelled/ignored. A cache hit cancels live; live commits on its first
///    complete speakable sentence. After commit, the source never swaps.
/// All mutable state and model writes are serialized onto the main queue. The unchecked
/// conformance documents that invariant for provider callbacks crossing concurrency domains.
final class TurnManager: @unchecked Sendable {
    enum TurnState { case listening, generating, presenting }

    private let model: AnswerModel
    private let generator: AnswerGenerator
    private let knowledge: KnowledgeProvider
    private let router: Router
    private let bank: AnswerBank?
    private let scriptStore: ScriptStore?
    let latency = LatencyMonitor()
    private let sttDebug = ProcessInfo.processInfo.environment["FI_STT_DEBUG"] == "1"

    private var epoch = 0
    private var state: TurnState = .listening
    private var committedEpoch = -1
    private var liveBuffer = ""
    private var liveIsCommittedSource = false
    private var liveTask: Task<Void, Never>?
    private var routerTask: Task<Void, Never>?
    private var currentQuestion = ""
    private var history: [(q: String, a: String)] = []   // 深掘り context

    var paused = false

    init(model: AnswerModel,
         generator: AnswerGenerator,
         knowledge: KnowledgeProvider = NullKnowledge(),
         router: Router = NullRouter(),
         bank: AnswerBank? = nil,
         scriptStore: ScriptStore? = nil) {
        self.model = model
        self.generator = generator
        self.knowledge = knowledge
        self.router = router
        self.bank = bank
        self.scriptStore = scriptStore
    }

    /// Feed STT events. Call on the main thread.
    func handleTranscript(_ t: Transcript) {
        guard !paused else { return }
        if !t.isFinal {
            if sttDebug { NSLog("[stt] … %@", t.text) } // interim — FI_STT_DEBUG=1 to watch
            return
        }
        let q = t.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isMeaningfulQuestion(q) else {
            NSLog("[turn] ignore backchannel: %@", q)
            return
        }
        // S2: see exactly what the interviewer's speech was recognized as (+confidence).
        NSLog("[stt] Q(%.2f): %@", t.confidence, q)
        startTurn(question: q)
    }

    /// Backchannel / too-short filter so 「なるほど」 doesn't trigger an answer (§6).
    private func isMeaningfulQuestion(_ q: String) -> Bool {
        if q.count < 4 { return false }
        let backchannel: Set<String> = [
            "はい", "ええ", "そうですね", "なるほど", "うん", "了解", "オーケー",
            "はい。", "なるほど。", "そうですね。",
        ]
        return !backchannel.contains(q)
    }

    private func startTurn(question: String) {
        epoch += 1
        let myEpoch = epoch
        liveTask?.cancel(); routerTask?.cancel()
        state = .generating
        liveBuffer = ""
        liveIsCommittedSource = false
        latency.turnStart(myEpoch)

        model.answer = ""
        model.errorDetail = nil
        model.intentLabel = ""
        model.question = question   // show what STT heard, so a mis-hear is caught before reading aloud
        model.status = .thinking
        model.message = .thinking

        // Source A: router/cache — user script (preferred) + AI bank, if any candidates.
        let cands = routeCandidates(for: question)
        if !cands.isEmpty {
            routerTask = Task { [weak self] in
                await self?.runRouter(question: question, cands: cands, myEpoch: myEpoch)
            }
        }

        // Source B: live generation — always, in parallel. Inject the prepared script as
        // grounding so a miss still produces an answer consistent with the user's wording.
        // Gated on the privacy toggle: when the user has opted out, the resume facts and
        // script are NOT sent to the cloud LLM (answers become generic).
        currentQuestion = question
        var ctx = ""
        if Settings.sendContextToLLM {
            ctx = knowledge.context(for: question)
            if let script = scriptStore?.contextBlock(), !script.isEmpty {
                ctx += (ctx.isEmpty ? "" : "\n\n") + script
            }
        }
        let req = GenRequest(question: question, context: ctx, history: historyText())
        liveTask = Task { [weak self] in
            await self?.runLive(req, myEpoch: myEpoch)
        }
    }

    // MARK: - Source A: router / cache

    /// Merge candidates for the Router: the user's hand-written script FIRST (so a tie
    /// resolves to the verbatim answer via Router's "lowest index" rule), then the AI bank.
    /// Skipped entirely when the user has opted out of sending context — the LLM router would
    /// otherwise receive the script/bank candidate questions.
    private func routeCandidates(for question: String) -> [BankEntry] {
        guard Settings.sendContextToLLM else { return [] }
        var cands = scriptStore?.candidates(for: question) ?? []
        if let bank { cands += bank.candidates(for: question) }
        return Array(cands.prefix(5))
    }

    private func runRouter(question: String, cands: [BankEntry], myEpoch: Int) async {
        let decision = try? await router.route(question: question, candidates: cands)
        await MainActor.run { [weak self] in
            guard let self, myEpoch == self.epoch else { return }
            guard let d = decision else { return }
            if !d.intent.isEmpty { self.model.intentLabel = d.intent }
            guard let ans = d.matchedAnswer, self.committedEpoch != myEpoch else { return }
            // Cache wins the turn.
            self.committedEpoch = myEpoch
            self.liveTask?.cancel()
            self.latency.markFirstReadable(epoch: myEpoch, kind: .cache)
            self.model.status = .streaming
            self.model.message = .suggesting
            self.model.answer = ans
            self.finishTurn(myEpoch)
        }
    }

    // MARK: - Source B: live generation (staged → commit on first complete sentence)

    private func runLive(_ req: GenRequest, myEpoch: Int) async {
        do {
            try await generator.generate(req, epoch: myEpoch) { [weak self] delta in
                guard let self else { return }
                DispatchQueue.main.async {
                    guard myEpoch == self.epoch else { return }
                    if self.committedEpoch == myEpoch && !self.liveIsCommittedSource { return } // cache won
                    self.liveBuffer += delta
                    if self.liveIsCommittedSource {
                        self.model.answer = SpokenAnswerFormatter.normalize(self.liveBuffer)
                    } else if self.hasSpeakableOpening(self.liveBuffer) {
                        guard self.committedEpoch != myEpoch else { return } // cache just committed
                        self.committedEpoch = myEpoch
                        self.liveIsCommittedSource = true
                        self.latency.markFirstReadable(epoch: myEpoch, kind: .live)
                        self.model.status = .streaming
                        self.model.message = .suggesting
                        self.model.answer = SpokenAnswerFormatter.normalize(self.liveBuffer)
                    }
                }
            }
            await finishLive(myEpoch)
        } catch is CancellationError {
            // superseded — silent
        } catch {
            await failTurn(myEpoch, error: error)
        }
    }

    /// Never reveal an unstable half-sentence. Japanese sentence punctuation is the
    /// preferred boundary; the length fallback prevents a provider that omits punctuation
    /// from blocking the UI indefinitely.
    private func hasSpeakableOpening(_ text: String) -> Bool {
        let boundaries = CharacterSet(charactersIn: "。！？!?\n")
        return text.count >= 12 && text.rangeOfCharacter(from: boundaries) != nil
            || text.count >= 90
    }

    @MainActor private func finishLive(_ myEpoch: Int) {
        guard myEpoch == epoch else { return }
        if committedEpoch != myEpoch {
            // very short answer that never tripped the commit threshold — commit now.
            committedEpoch = myEpoch
            liveIsCommittedSource = true
            latency.markFirstReadable(epoch: myEpoch, kind: .live)
            model.status = .streaming
            model.message = .suggesting
        }
        guard liveIsCommittedSource else { return } // cache owns the turn
        model.answer = SpokenAnswerFormatter.normalize(liveBuffer)
        finishTurn(myEpoch)
    }

    @MainActor private func finishTurn(_ myEpoch: Int) {
        guard myEpoch == epoch else { return }
        latency.turnEnd(myEpoch)
        state = .presenting
        model.status = .presenting
        model.message = .completed
        recordHistory()
    }

    private func recordHistory() {
        guard !currentQuestion.isEmpty else { return }
        history.append((q: currentQuestion, a: String(model.answer.prefix(200))))
        if history.count > 4 { history.removeFirst(history.count - 4) }
    }

    private func historyText() -> String {
        guard !history.isEmpty else { return "" }
        return history.suffix(3).map { "Q: \($0.q)\nA: \($0.a)" }.joined(separator: "\n")
    }

    @MainActor private func failTurn(_ myEpoch: Int, error: Error) {
        guard myEpoch == epoch, committedEpoch != myEpoch else { return }
        model.status = .error
        model.message = .generationError
        model.errorDetail = error.localizedDescription
    }
}
