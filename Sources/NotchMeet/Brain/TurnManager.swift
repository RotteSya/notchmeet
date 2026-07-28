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

    // Utterance coalescing (§6). 面接官は一続きの発話で「意見の表明・前置き＋本題」を話す：
    //   「なるほど、〜だと思います。」〔思考の間〕「その点、どうお考えですか？」
    // Deepgram は句点ごとに final を返すので、前半（表明）だけで答えると本題を取りこぼし、回答が
    // 本題とズレて割れる。実機で報告された「発表の想法と質問を2題に割る」症状はこれ。対策は2段構え：
    //   (1) 確定待ちの窓を発話の種類で変える。完結した質問・依頼（…か／？／…ください）は即答して
    //       よいので短い窓、ただの意見表明（…です／…と思います。）は本題がまだ続く可能性が高いので
    //       長い窓で待ち、本題を同じターンに畳み込む（looksLikeCompletedPrompt）。
    //   (2) それでも間が空いて表明だけ確定してしまった場合の保険＝リコール・マージ：直後(mergeGrace)に
    //       本題が来たら、そのターンを開き直して〔表明＋本題〕を1問として答え直す（armMerge）。
    private var pendingQ = ""
    private var settleWork: DispatchWorkItem?
    /// 最后一个被接受的终稿到达时刻（uptime ns），供 LatencyMonitor 拆分端点延迟。
    private var lastFinalNs: UInt64 = 0
    /// 完了した質問・依頼（…か／？／…ください）だけ、この短い静寂で確定＝即答する。実面接の端末内
    /// 計測では質問の途中に入る息継ぎは 0.5〜0.8s なので、0.8s ならそれを跨がずに最速で出せる。
    /// ただの陳述文はここでは確定しない（settleWindowMax を使う）。FI_SETTLE_MS（ミリ秒）で上書き可。
    private let settleWindow: TimeInterval = {
        if let s = ProcessInfo.processInfo.environment["FI_SETTLE_MS"], let v = Double(s), v >= 0 {
            return v / 1000
        }
        return 0.8
    }()
    /// 静寂の最大待ち。意見表明・前置きの後に本題が続くケースや、途中で切れた言い淀み（「…なぜ」）で使う。
    /// 実測（2026-07-01 の実面接を端末内で文字起こしして計測）：面接官の「前置き/意見 → 本題」の間は
    /// 概ね 0.7〜1.4s。余裕を見て 1.8s とし、これを超える尾はリコール・マージ（mergeGrace）が拾う。
    /// 本番は面接官チャンネルのみ聞くため、本当の話者交代は候補者の発話ぶん数秒以上空く＝早すぎる確定の心配なし。
    /// FI_SETTLE_MAX_MS（ミリ秒）で上書き可。
    private let settleWindowMax: TimeInterval = {
        if let s = ProcessInfo.processInfo.environment["FI_SETTLE_MAX_MS"], let v = Double(s), v >= 0 {
            return v / 1000
        }
        return 1.8
    }()

    // Recall-merge net (§6, layer 2). A commit that was only a *statement* (setup, not a question or
    // request) very likely precedes the real question. If a meaningful final lands within `mergeGrace`
    // of such a commit, fold it back into that turn so the answer sees the whole question instead of
    // the tail stripped of its setup. FI_MERGE_GRACE_MS (ms) overrides.
    private var mergeArmed = false
    private var mergeWork: DispatchWorkItem?
    private var lastCommittedQ = ""
    private let mergeGrace: TimeInterval = {
        if let s = ProcessInfo.processInfo.environment["FI_MERGE_GRACE_MS"], let v = Double(s), v >= 0 {
            return v / 1000
        }
        return 2.5
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
        // 终稿到达时刻 —— 延迟拆分用。它把「等 STT 交付」与「我们 settle 等待」分开：
        // 只看合并后的端点延迟时，一次 4.5s 无法区分该调窗口还是该查网络。
        lastFinalNs = DispatchTime.now().uptimeNanoseconds
        // Layer 2 (recall-merge): the previous turn committed only a statement (setup) and the
        // interviewer has continued within the grace window → reopen that turn so the answer sees the
        // whole question, not just the tail. startTurn (fired by settle below) then supersedes the
        // stale generation via the epoch bump, and we drop the premature setup-only history entry.
        if mergeArmed, pendingQ.isEmpty {
            disarmMerge()
            pendingQ = lastCommittedQ
            if history.last?.q == lastCommittedQ { history.removeLast() }
            NSLog("[turn] merge-recall: folding follow-up into prior setup")
        }
        pendingQ = pendingQ.isEmpty ? q : pendingQ + " " + q
        armSettle()
    }

    /// (Re)arm the settle timer; every new final/interim pushes the commit out. A completed question
    /// or request commits after the short `settleWindow`; a bare statement (or a clause that trails
    /// off) waits `settleWindowMax`, so an interviewer who states a view before the real question
    /// (「…と思います。」→〔思考の間〕→本題) lands as ONE turn instead of splitting.
    /// The window is defined as silence measured FROM THE LAST PHONEME — the STT engine already
    /// consumed part of it before its final arrived (Apple 端点器 ~0.7s、Deepgram endpointing 0.3s)，
    /// so that banked silence is credited instead of waited twice (§4 预算里最大的一块固定浪费).
    private func armSettle() {
        settleWork?.cancel()
        let window = looksLikeCompletedPrompt(pendingQ) ? settleWindow : settleWindowMax
        let delay = max(0, window - bankedSilence())
        let work = DispatchWorkItem { [weak self] in self?.commitPending() }
        settleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Silence already elapsed since the audio path's last speech-level frame (`voicedClock`,
    /// same source as the §4 T0). Trusted only when fresh (≤5s): a missing/mock audio path (0),
    /// a future stamp, or a stale one degrades to the old wait-the-full-window behavior. The
    /// clock's VAD is MORE sensitive than the STT endpointer's (peak 300 vs RMS 0.012), so the
    /// credit only ever under-counts silence — never commits earlier than the window intends.
    private func bankedSilence() -> TimeInterval {
        guard let clock = latency.voicedClock else { return 0 }
        let voiced = clock()
        let now = DispatchTime.now().uptimeNanoseconds
        guard voiced > 0, voiced <= now else { return 0 }
        let s = Double(now &- voiced) / 1_000_000_000
        return s <= 5 ? s : 0
    }

    /// Has the interviewer actually FINISHED and handed the floor over — i.e. is this a complete
    /// question (…か／？) or a direct request (…ください／お願いします)? Those get the short window
    /// (answer promptly). A bare declarative statement (…です／…と思います。) is NOT a hand-off: an
    /// interviewer who just stated a view is almost always still building toward the real question,
    /// so it gets the long window and we fold the question into the same turn. This distinction —
    /// "sentence-complete" ≠ "turn-complete" — is the core of the over-splitting fix.
    private func looksLikeCompletedPrompt(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = t.last else { return false }
        if "？?".contains(last) { return true }                    // explicit question mark
        // strip trailing sentence punctuation, then inspect the real ending
        let core = t.trimmingCharacters(in: CharacterSet(charactersIn: "　 。．、…!！?？"))
        guard let c = core.last else { return false }
        if c == "か" { return true }                               // …ですか／…ましたか／…でしょうか
        // direct requests / imperatives that ARE a prompt to answer now
        for tail in ["ください", "下さい", "お願いします", "お願いいたします"] {
            if core.hasSuffix(tail) { return true }
        }
        return false
    }

    private func cancelSettle() {
        settleWork?.cancel(); settleWork = nil; pendingQ = ""
        disarmMerge()   // a pause/stop ends the turn — never merge across it
    }

    /// Silence held for `settleWindow` → the interviewer finished. Commit the coalesced finals
    /// as ONE question and start the turn.
    private func commitPending() {
        settleWork = nil
        let q = pendingQ.trimmingCharacters(in: .whitespacesAndNewlines)
        pendingQ = ""
        guard !q.isEmpty, !paused else { return }
        // 面试官问题原文只在显式开启 STT 调试时落日志。NSLog 默认 public，会进
        // /var/db/diagnostics 保留数天，并随 sysdiagnose 一起外泄——而「删除本地数据」
        // 清不掉系统日志。默认只记长度，足够诊断「有没有收到问题」。
        if sttDebug { NSLog("[stt] Q: %@", q) } else { NSLog("[stt] Q received (%d chars)", q.count) }
        // Arm the recall-merge net only when committing a *statement*: a question that lands right
        // after should fold back in (layer 2). A completed question/request needs no net.
        lastCommittedQ = q
        if looksLikeCompletedPrompt(q) { disarmMerge() } else { armMerge() }
        startTurn(question: q)
    }

    /// Hold the "just committed a statement" window open for `mergeGrace`; a follow-up final inside
    /// it is treated as the real question and folded back (see `handleTranscript`).
    private func armMerge() {
        mergeWork?.cancel()
        mergeArmed = true
        let work = DispatchWorkItem { [weak self] in self?.mergeArmed = false; self?.mergeWork = nil }
        mergeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + mergeGrace, execute: work)
    }

    private func disarmMerge() {
        mergeWork?.cancel(); mergeWork = nil; mergeArmed = false
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
        latency.turnStart(myEpoch, sttFinalNs: lastFinalNs)

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
        var hist = ""
        if Settings.sendContextToLLM {
            ctx = knowledge.context(for: question)
            if let script = scriptStore?.contextBlock(for: question), !script.isEmpty {
                ctx += (ctx.isEmpty ? "" : "\n\n") + script
            }
            hist = historyText()   // same privacy gate as facts: opted out → no 流れ leaves the device
        }
        let req = GenRequest(question: question, context: ctx, history: hist)
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
        let decision: RouteDecision? = await {
            do {
                return try await router.route(question: question, candidates: cands)
            } catch {
                // 旧实现是 `try?`：路由 LLM 持续 429 时，整场面试从不命中原稿、全走 live
                // 生成，与「真的没匹配上」在现场完全无法区分——正是「答案不是我准备的
                // 回答」类事故的诊断盲区。
                NSLog("[router] route failed (turn %d): %@", myEpoch, String(describing: error))
                return nil
            }
        }()
        await MainActor.run { [weak self] in
            guard let self, myEpoch == self.epoch else { return }
            guard let d = decision else { return }
            if !d.intent.isEmpty { self.model.intentLabel = d.intent }
            guard let ans = d.matchedAnswer else { return }
            if self.committedEpoch != myEpoch {
                // Cache wins the turn.
                self.committedEpoch = myEpoch
                self.liveTask?.cancel()
                self.latency.markFirstReadable(epoch: myEpoch, kind: .cache)
                self.commitAnswer(ans, myEpoch: myEpoch)
            } else if self.liveIsCommittedSource, self.state != .presenting {
                // Live's first sentence beat the router, but the user WROTE this answer —
                // while the live text is still growing (nobody has finished reading it),
                // swapping to the verbatim script is strictly better than an invented one.
                // Once the answer has settled (.presenting) we never swap mid-read.
                NSLog("[router] late hit (turn %d): replacing streaming live answer with 原稿", myEpoch)
                self.liveTask?.cancel()
                self.liveIsCommittedSource = false   // late live deltas are dropped by runLive's guard
                self.commitAnswer(ans, myEpoch: myEpoch)
            } else {
                // Diagnosability: before this log existed, a lost race was indistinguishable
                // from a router miss in the field (the "answer isn't my script" reports).
                NSLog("[router] late hit (turn %d): answer already settled — 原稿 dropped", myEpoch)
            }
        }
    }

    @MainActor private func commitAnswer(_ ans: String, myEpoch: Int) {
        model.status = .streaming
        model.message = .suggesting
        model.answer = ans
        finishTurn(myEpoch)
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
        } catch where Self.isCancellation(error) {
            // superseded — silent
        } catch {
            await failTurn(myEpoch, error: error)
        }
    }

    /// 取消不是故障。
    ///
    /// 这个区分是实测逼出来的：原稿命中时 `liveTask?.cancel()` 会取消 live 生成，
    /// 而 **URLSession 用 `URLError.cancelled`(-999) 表达取消，不是 Swift 并发的
    /// `CancellationError`**。只认后者的话，每一轮正常的缓存命中都会被当成「已提交后
    /// 流中断」，给一条完好的逐字稿答案挂上「连接中断，这段回答可能不完整」的假警报。
    /// 实测中 turn 5/6/7 连续三轮都命中了这条。
    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        let ns = error as NSError
        return ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled
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
        let final = SpokenAnswerFormatter.normalize(liveBuffer)
        guard !final.isEmpty else {
            // provider 返回零内容（安全拦截/空补全）。旧实现照样 commit：刘海显示
            // 「可直接作答」而正文空白——比明确报错更糟。
            NSLog("[turn] live produced no usable text (turn %d)", myEpoch)
            committedEpoch = -1
            liveIsCommittedSource = false
            model.answer = ""
            model.status = .error
            model.message = .generationError
            model.errorDetail = AppStrings.current.answerEmpty
            return
        }
        model.answer = final
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
        history.append((q: currentQuestion, a: String(model.answer.prefix(300))))
        if history.count > 6 { history.removeFirst(history.count - 6) }
    }

    private func historyText() -> String {
        guard !history.isEmpty else { return "" }
        // Labels mark provenance honestly: 面接官 is what STT actually heard; 回答案 is the answer
        // WE suggested last turn — not necessarily what the candidate said (the app never hears them).
        return history.suffix(4).map { "面接官: \($0.q)\n回答案: \($0.a)" }.joined(separator: "\n\n")
    }

    @MainActor private func failTurn(_ myEpoch: Int, error: Error) {
        guard myEpoch == epoch else { return }
        guard committedEpoch != myEpoch else {
            // 已经上屏之后才失败（网络中途断开）。旧实现在这里直接 return，回合永远停在
            // .streaming：用户对着半截答案，状态行一直显示「生成中」，面板不折叠，
            // 该回合也不进 history（下一问的深掘去重少一环），LatencyMonitor 还会漏账。
            // 正确的收尾是把已有内容定格为完成态，并附上「可能不完整」的提示。
            NSLog("[turn] stream failed after commit (turn %d): %@",
                  myEpoch, String(describing: error))
            if liveIsCommittedSource {
                model.answer = SpokenAnswerFormatter.normalize(liveBuffer)
            }
            model.errorDetail = AppStrings.current.answerMayBeIncomplete
            finishTurn(myEpoch)
            return
        }
        model.answer = ""        // 未コミット → 残っている前ターンの答えを消し、エラーを見せる
        model.status = .error
        model.message = .generationError
        model.errorDetail = error.localizedDescription
    }
}
