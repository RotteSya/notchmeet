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

    // Utterance coalescing (§6). 日本人面接官は「よろしくお願いします。まず自己紹介を…」のように
    // 寒暄＋本題を一続きで話す。Deepgram は句点ごとに final を返すため、本題を待たずに前半だけで
    // 答えてしまっていた。final が来てもすぐターンを起こさず、`settleWindow` の静寂が続いて初めて
    // その間の final 群を 1 つの質問として確定する。
    private var pendingQ = ""
    private var settleWork: DispatchWorkItem?
    /// 文が「。！？／…か」で終わっていれば、この静寂で確定（完了文＝即答えてよい）。
    /// FI_SETTLE_MS（ミリ秒）で上書き可。
    private let settleWindow: TimeInterval = {
        if let s = ProcessInfo.processInfo.environment["FI_SETTLE_MS"], let v = Double(s), v >= 0 {
            return v / 1000
        }
        return 0.8
    }()
    /// 文が途中で切れているとき（述語なしの言い淀み「…なぜ」等）に待つ最大の静寂。実機ログでは
    /// 面接官が ~1.0s 黙ってから本題を続けるので、短い窓だと割れる。FI_SETTLE_MAX_MS で上書き可。
    private let settleWindowMax: TimeInterval = {
        if let s = ProcessInfo.processInfo.environment["FI_SETTLE_MAX_MS"], let v = Double(s), v >= 0 {
            return v / 1000
        }
        return 1.6
    }()

    var paused = false {
        didSet { if paused { cancelSettle() } }   // 録音停止/デモ中: 聞きかけの発話を捨てる
    }

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

    /// Feed STT events. Call on the main thread. Finals are not answered immediately; they are
    /// coalesced across `settleWindow` so a 寒暄＋本題 utterance becomes ONE turn (see above).
    func handleTranscript(_ t: Transcript) {
        guard !paused else { return }
        if !t.isFinal {
            if sttDebug { NSLog("[stt] … %@", t.text) } // interim — FI_STT_DEBUG=1 to watch
            // 面接官がまだ話している。確定待ちの発話があれば確定を先送りし、本題まで取り込む。
            if !pendingQ.isEmpty { armSettle() }
            return
        }
        let q = t.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isMeaningfulQuestion(q) else {
            NSLog("[turn] ignore backchannel: %@", q)
            return
        }
        // S2: see exactly what the interviewer's speech was recognized as (+confidence).
        if sttDebug { NSLog("[stt] final(%.2f): %@", t.confidence, q) }
        pendingQ = pendingQ.isEmpty ? q : pendingQ + " " + q
        armSettle()
    }

    /// (Re)arm the settle timer; every new final/interim pushes the commit out. A complete-looking
    /// utterance commits after `settleWindow`; one that trails off mid-clause waits `settleWindowMax`
    /// so a hesitating interviewer (「…なぜ」→〔間〕→本題) lands as ONE turn instead of splitting.
    private func armSettle() {
        settleWork?.cancel()
        let delay = looksComplete(pendingQ) ? settleWindow : settleWindowMax
        let work = DispatchWorkItem { [weak self] in self?.commitPending() }
        settleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Does the buffered utterance look like a finished question/sentence? 日本語は文末がはっきり
    /// する（句点・疑問符・終助詞「か」）。途中で切れていれば未完とみなして長く待つ。
    private func looksComplete(_ s: String) -> Bool {
        guard let last = s.trimmingCharacters(in: .whitespacesAndNewlines).last else { return false }
        return "。．！？!?".contains(last) || last == "か"
    }

    private func cancelSettle() {
        settleWork?.cancel(); settleWork = nil; pendingQ = ""
    }

    /// Silence held for `settleWindow` → the interviewer finished. Commit the coalesced finals
    /// as ONE question and start the turn.
    private func commitPending() {
        settleWork = nil
        let q = pendingQ.trimmingCharacters(in: .whitespacesAndNewlines)
        pendingQ = ""
        guard !q.isEmpty, !paused else { return }
        NSLog("[stt] Q: %@", q)
        startTurn(question: q)
    }

    /// Backchannel / greeting / too-short filter so 「なるほど」 や単独の「よろしくお願いします」 が
    /// 答えを誘発しないようにする（§6）。末尾の句読点を外してから照合するので「なるほど。」「なるほど！」
    /// もまとめて弾く。長さ判定は元テキストのまま（terse な質問「強みは？」を巻き込まない）。
    private func isMeaningfulQuestion(_ q: String) -> Bool {
        if q.count < 4 { return false }
        let core = q.trimmingCharacters(in: CharacterSet(charactersIn: "　 。．、…!！?？"))
        let skip: Set<String> = [
            "はい", "ええ", "うん", "そうですね", "なるほど", "なるほどですね",
            "了解", "オーケー", "わかりました", "承知しました", "いいですね",
            // 開始/終了の寒暄（単独で出たとき。本題が続けば settle で本題に連結される）
            "よろしくお願いします", "よろしくお願いいたします",
            "本日はよろしくお願いします", "それではよろしくお願いします",
            "ありがとうございます", "ありがとうございました",
            "お願いします", "失礼します", "失礼いたします",
        ]
        return !skip.contains(core)
    }

    private func startTurn(question: String) {
        epoch += 1
        let myEpoch = epoch
        liveTask?.cancel(); routerTask?.cancel()
        state = .generating
        liveBuffer = ""
        liveIsCommittedSource = false
        latency.turnStart(myEpoch)

        // 前ターンの答えはここでは消さない。新しい答えの先頭文が確定するまで（runRouter / runLive の
        // コミット点で上書き）画面に残し、考え中の一瞬だけ薄く表示する → 「答えが一度消える」体験を防ぐ。
        // 失敗時のみ failTurn でクリアしてエラーを見せる。
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
        model.answer = ""        // 未コミット → 残っている前ターンの答えを消し、エラーを見せる
        model.status = .error
        model.message = .generationError
        model.errorDetail = error.localizedDescription
    }
}
