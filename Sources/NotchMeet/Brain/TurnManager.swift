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
    /// 编译好的画像索引。nil 时回退到整表 `knowledge.context` + `scriptStore.contextBlock`
    ///（单测不必为每个回合搭一份简历）。
    private let portrait: PortraitIndex?
    /// 供临场回看的全文记录（与下面那份喂 LLM 的摘要 `history` 分开，见 AnswerHistory）。
    private let answerHistory: AnswerHistory?
    let latency = LatencyMonitor()
    private let sttDebug = ProcessInfo.processInfo.environment["FI_STT_DEBUG"] == "1"

    private var epoch = 0
    private var state: TurnState = .listening
    private var committedEpoch = -1
    private var liveBuffer = ""
    private var liveIsCommittedSource = false
    /// 上屏刷新已排队（见 runLive 的合批注释）。只在主队列上读写。
    private var liveFlushScheduled = false
    /// 本轮 live 流已收束（finishLive/failTurn 已处理，含错误分支）。迟到的 flushLive
    /// 必须作废：没有这道闸，它会把刚落地的 error 态改写回「可作答」，或重新提交一段
    /// 永远不会 finishTurn 的半截答案——正是旧「delta 内同步提交」隐式防住的两类事故。
    private var liveClosed = false
    private var liveTask: Task<Void, Never>?
    private var routerTask: Task<Void, Never>?
    private var currentQuestion = ""
    /// 本轮答案的来源，供复盘统计（哪些问题命中了我准备的内容、哪些是现场编的）。
    private var currentSource: AnswerSource = .live
    /// 一轮定稿后回调（question, answer, source）。AppController 接到 SessionStore。
    var onTurnRecorded: ((String, String, AnswerSource) -> Void)?
    /// recall-merge 撤回过早定稿的那一轮（与下面 history.removeLast 同一时机）。
    var onTurnRetracted: ((String) -> Void)?
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
    /// `looksLikeCompletedPrompt(pendingQ)` 的缓存。interim 只是推迟定稿、不改 pendingQ，
    /// 而 armSettle 每条 interim 都会重跑——对完全相同的字符串按 5-10Hz 重算一遍
    /// trim + 词表扫描纯属浪费。只在 pendingQ 真正变化的两处（final 追加 / 清空）重算。
    private var pendingQCompleted = false
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
        didSet { if paused { cancelSettle(); cancelSpeculate() } }   // 録音停止/デモ中: 聞きかけの発話を捨てる
    }

    // Speculative generation on a stable, complete-looking interim (PLAN §7).
    // Fires *before* STT final + settle so LLM TTFT overlaps the endpointer.
    // Confirmation (and any persist) waits for the coalesced final — a speculative
    // FactQuickAnswer / cache hit must not land in SessionStore or history.
    private var speculative = false
    private var specQuestion = ""
    private var specStartsThisUtterance = 0
    private var specDebounce: DispatchWorkItem?
    private var specCandidate = ""
    private var persistDeferred = false
    private var lastUsedSlotIDs: [String] = []
    private var currentUsedSlotIDs: [String] = []
    private var specFired = 0
    private var specReused = 0
    private var specMissed = 0
    private var specRestarted = 0
    /// 投机去抖。Natively 原型 350ms；FI_SPECULATE_MS=0 关闭。
    private let speculateWindow: TimeInterval = {
        if let s = ProcessInfo.processInfo.environment["FI_SPECULATE_MS"], let v = Double(s), v >= 0 {
            return v / 1000
        }
        return 0.35
    }()
    /// 同一话轮最多开 2 次（首次 + 一次加长重启），挡住 Apple interim 的重启风暴。
    private let maxSpecStarts = 2

    /// 本场会话的面试语言快照。armLive 装配时定死，与同场 STT 引擎的语言同源——
    /// 面试中途改设置只影响下一次开始录音，绝不让 prompts/history/门控在半场换语言。
    var interviewLanguage: InterviewLanguage = .japanese

    init(model: AnswerModel,
         generator: AnswerGenerator,
         knowledge: KnowledgeProvider = NullKnowledge(),
         router: Router = NullRouter(),
         bank: AnswerBank? = nil,
         scriptStore: ScriptStore? = nil,
         answerHistory: AnswerHistory? = nil,
         portrait: PortraitIndex? = nil) {
        self.model = model
        self.generator = generator
        self.knowledge = knowledge
        self.router = router
        self.bank = bank
        self.scriptStore = scriptStore
        self.answerHistory = answerHistory
        self.portrait = portrait
    }

    /// Feed STT events. Call on the main thread. Finals are not answered immediately; they are
    /// coalesced across `settleWindow` so a 寒暄＋本題 utterance becomes ONE turn (see above).
    func handleTranscript(_ t: Transcript) {
        guard !paused else { return }
        if !t.isFinal {
            if sttDebug { NSLog("[stt] … %@", t.text) } // interim — FI_STT_DEBUG=1 to watch
            // 面接官がまだ話している。確定待ちの発話があれば確定を先送りし、本題まで取り込む。
            if !pendingQ.isEmpty { armSettle() }
            armSpeculate(interim: t.text)
            return
        }
        cancelSpeculateDebounce()
        let q = t.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isMeaningfulQuestion(q) else {
            // 与 commitPending 同一条策略：转录原文只在显式开启 STT 调试时落日志。
            // 这一支是 a0d33c3 那次修复漏掉的——而它恰恰最常触发（判据之一是长度 < 4，
            // 任何 STT 碎片、误识、断句尾巴都会走到这里），等于把面试官说的话
            // 一片片写进系统日志。
            if sttDebug { NSLog("[turn] ignore backchannel: %@", q) }
            else { NSLog("[turn] ignore backchannel (%d chars)", q.count) }
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
            onTurnRetracted?(lastCommittedQ)
            NSLog("[turn] merge-recall: folding follow-up into prior setup")
        }
        pendingQ = pendingQ.isEmpty ? q : pendingQ + " " + q
        pendingQCompleted = looksLikeCompletedPrompt(pendingQ)
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
        let window = pendingQCompleted ? settleWindow : settleWindowMax
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
    func looksLikeCompletedPrompt(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = t.last else { return false }
        if "？?".contains(last) { return true }                    // explicit question mark
        // strip trailing sentence punctuation, then inspect the real ending
        let core = t.trimmingCharacters(in: Self.questionTrimSet)
        guard let c = core.last else { return false }
        switch interviewLanguage {
        case .japanese:
            if c == "か" { return true }                           // …ですか／…ましたか／…でしょうか
            // direct requests / imperatives that ARE a prompt to answer now
            for tail in ["ください", "下さい", "お願いします", "お願いいたします"] {
                if core.hasSuffix(tail) { return true }
            }
            return false
        case .chinese:
            // 端侧 zh-CN 终稿常无「？」（Apple 引擎是国内推荐路径），只靠问号会让
            // 每个中文问题都吃满长 settle 窗口。语气助词尾（吗/呢）= 交棒；其余疑问
            // 信号一律走 zhLooksInterrogative——尾缀必然落在最后一个分句里，而那里
            // 每个疑问词都绑着陈述用法排除项。在这里保留旧尾词表先行短路的话，
            // 「我这边没什么」会以尾缀「什么」直接判成交棒，排除项永远失效。
            if core.hasSuffix("吗") || core.hasSuffix("呢") { return true }
            // 3 字短问（「为什么」）不算交棒：它更可能是长问题在停顿处被切出的头一截，
            // 长窗口 + armMerge 让后半句折回同一轮；孤立短追问晚 ~1s 提交无伤大雅。
            guard core.count >= 4 else { return false }
            return Self.zhLooksInterrogative(core)
        }
    }

    /// 中文疑问信号大多在句中而非句尾——「为什么选择我们**公司**」「你觉得这个方案有什么
    /// **问题**」句尾都是名词，尾词表照不到，这类问题此前全部吃满 1.8s 长窗口
    /// （比短窗口每问多白等约 1 秒）。误判为「已交棒」的代价是：短窗提交 + 解除
    /// recall-merge 网，铺垫句与后续本题被拆开；所以判定收窄成三道闸：
    ///  - 疑问代词/正反问只查**最后一个分句**。分隔符包含句读与空格——pendingQ 是
    ///    多条终稿用空格拼接的累积体（handleTranscript），只按逗号切时「大家都问
    ///    为什么。我先介绍一下公司」整串就是一个分句，收窄对跨句输入整体失效。
    ///  - 每个疑问词绑定自己的陈述用法排除项（没什么/几乎/不怎么…），词与排除项
    ///    在同一行声明，不靠行序表达依赖。
    ///  - 祈使型提问要求第二人称/「自己」锚定，且紧邻前字不得是 我/先/来/们——
    ///    「介绍一下你自己」是提问，「我先介绍一下自己，我是技术负责人」是开场白。
    static func zhLooksInterrogative(_ core: String) -> Bool {
        let clause = core.split(whereSeparator: { Self.zhClauseSeparators.contains($0) })
            .last.map(String.init) ?? core
        if Self.zhClauseMarkers.contains(where: { marker, unless in
            clause.contains(marker) && !unless.contains(where: clause.contains)
        }) { return true }
        // 显式「请 + 动词」祈使（「请介绍一下你自己」「请聊聊你们的项目」）。
        if core.hasPrefix("请"), Self.zhAskVerbs.contains(where: core.contains) { return true }
        // 不带「请」的祈使型提问（全句扫描：动词在句首、修饰语在句尾，最后分句常照不到）。
        for marker in Self.zhImperativeAsks {
            guard let r = core.range(of: marker) else { continue }
            if r.lowerBound == core.startIndex { return true }
            if !"我先来们".contains(core[core.index(before: r.lowerBound)]) { return true }
        }
        return false
    }

    /// 最后分句的切分符：句内停顿 + 句间句读 + 空格（pendingQ 的终稿拼接符）。
    private static let zhClauseSeparators: Set<Character> =
        ["，", ",", "、", "；", ";", "。", "．", ".", "！", "!", "？", "?", "…", " ", "　"]
    /// (疑问标记, 陈述用法排除项)。排除项按「包含即否决」在同一分句内判定。
    private static let zhClauseMarkers: [(String, [String])] = [
        // A-not-A 正反问：出现即交棒。
        ("是不是", []), ("有没有", []), ("能不能", []), ("会不会", []), ("可不可以", []),
        ("愿不愿意", []), ("行不行", []), ("对不对", []), ("要不要", []),
        // 疑问代词/副词。「几个/几年/几次」刻意不收：量词陈述（我做了几年后端）远多于疑问。
        ("为什么", []), ("为啥", []),
        ("什么", ["没什么", "没有什么", "什么的", "几乎"]),
        ("怎么", ["不怎么", "没怎么", "不管怎么", "无论怎么", "几乎"]),
        ("如何", ["无论如何", "不管如何"]),
        ("哪", ["哪怕"]),
        ("多少", ["多少有点", "或多或少", "几乎"]),
        ("多久", []), ("多长时间", []),
        ("谁", ["谁都", "谁也"]),
    ]
    private static let zhAskVerbs = ["介绍", "谈", "说", "讲", "聊", "描述", "分享", "举"]
    private static let zhImperativeAsks = [
        "介绍一下你", "介绍一下自己", "说说你", "谈谈你", "讲讲你", "聊聊你",
        "说一下你", "讲一下你", "谈一下你", "分享一下你", "描述一下你",
        "举个例子", "举一个例子",
    ]
    /// 3 字口语填充：含疑问字形但不是提问，短问放行分支必须过滤（skip 表对 <4 字不可达）。
    private static let zhShortFillers: Set<String> = ["怎么说", "那什么", "是不是", "对不对", "什么呀", "好的呢"]

    private func cancelSettle() {
        settleWork?.cancel(); settleWork = nil; pendingQ = ""; pendingQCompleted = false
        disarmMerge()   // a pause/stop ends the turn — never merge across it
        cancelSpeculateDebounce()
    }

    // MARK: - Speculative open (interim)

    /// Candidate text for speculation: already-finalized clauses plus the live interim.
    /// Naked interim alone never looks complete when Deepgram splits on punctuation.
    private func speculativeCandidate(interim: String) -> String {
        let t = interim.trimmingCharacters(in: .whitespacesAndNewlines)
        if pendingQ.isEmpty { return t }
        if t.isEmpty { return pendingQ }
        return pendingQ + " " + t
    }

    private func armSpeculate(interim: String) {
        guard speculateWindow > 0, !paused else { return }
        let text = speculativeCandidate(interim: interim)
        guard isMeaningfulQuestion(text), looksLikeCompletedPrompt(text) else {
            cancelSpeculateDebounce()
            return
        }
        // Same complete question already in flight — don't re-debounce.
        if speculative, TurnSpeculation.covers(spec: specQuestion, final: text,
                                               language: interviewLanguage),
           TurnSpeculation.normalize(text) == TurnSpeculation.normalize(specQuestion) {
            return
        }
        let growing = speculative && text.count >= specQuestion.count + 4
        if growing {
            guard specStartsThisUtterance < maxSpecStarts else { return }
        } else if speculative {
            // Volatile rewrite that isn't a real lengthening — wait for stability
            // on the new string, but don't increment the restart cap until fire.
        }
        specCandidate = text
        specDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.fireSpeculate() }
        specDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + speculateWindow, execute: work)
    }

    private func fireSpeculate() {
        specDebounce = nil
        guard !paused, speculateWindow > 0 else { return }
        let text = specCandidate
        guard !text.isEmpty, isMeaningfulQuestion(text), looksLikeCompletedPrompt(text) else { return }
        if speculative, TurnSpeculation.covers(spec: specQuestion, final: text,
                                               language: interviewLanguage),
           TurnSpeculation.normalize(text) == TurnSpeculation.normalize(specQuestion) {
            return
        }
        if specStartsThisUtterance >= maxSpecStarts { return }
        if speculative { specRestarted += 1 }
        specFired += 1
        // 只停 settle 计时，留下 pendingQ。陈述句的长窗若在投机之后到期，
        // 会拿半截终稿去「确认」一句更长的投机问句，多问或前缀+本题都会被裁掉。
        settleWork?.cancel(); settleWork = nil
        startTurn(question: text, speculative: true)
        logSpecRate(event: specStartsThisUtterance > 1 ? "restart" : "fire")
    }

    private func confirmSpeculation(finalQuestion: String) {
        specReused += 1
        speculative = false
        specQuestion = ""
        specStartsThisUtterance = 0
        currentQuestion = finalQuestion
        model.question = finalQuestion
        latency.restamp(epoch, sttFinalNs: lastFinalNs)
        logSpecRate(event: "reuse")
        if persistDeferred {
            persistDeferred = false
            MainActor.assumeIsolated { persistTurn(epoch) }
        }
    }

    private func cancelSpeculateDebounce() {
        specDebounce?.cancel(); specDebounce = nil
    }

    private func cancelSpeculate() {
        cancelSpeculateDebounce()
        specCandidate = ""
        specStartsThisUtterance = 0
        speculative = false
        specQuestion = ""
        persistDeferred = false
    }

    private func logSpecRate(event: String) {
        NSLog("[spec] %@ fired=%d reused=%d missed=%d restarted=%d",
              event, specFired, specReused, specMissed, specRestarted)
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
        if speculative {
            let specCoversFinal = TurnSpeculation.covers(spec: specQuestion, final: q,
                                                         language: interviewLanguage)
            let finalCoversSpec = TurnSpeculation.covers(spec: q, final: specQuestion,
                                                         language: interviewLanguage)
            if specCoversFinal && finalCoversSpec {
                confirmSpeculation(finalQuestion: q)
                return
            }
            if specCoversFinal && !finalCoversSpec {
                // 终稿只是投机问句的前缀（陈述句 settle 抢跑）。把文本放回窗口，等后续终稿。
                pendingQ = q
                pendingQCompleted = looksLikeCompletedPrompt(q)
                return
            }
            specMissed += 1
            logSpecRate(event: "miss")
        }
        startTurn(question: q, speculative: false)
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
    func isMeaningfulQuestion(_ q: String) -> Bool {
        let core = q.trimmingCharacters(in: Self.questionTrimSet)
        if q.count < 4 {
            // 中文短追问是真问题：「为什么」「然后呢」在端侧 zh-CN 终稿里常以裸形式
            // 出现（无问号，3 字），旧的 4 字长度闸把它们当寒暄整条吞掉——面试官的
            // 追问石沉大海。只对中文、且带疑问信号的 3 字形式放行；口语填充
            // （怎么说/是不是）仍要滤掉——它们会取消在途生成、烧一次计费调用，落在
            // mergeGrace 内还会触发 merge-recall 撤回上一轮完好的定稿。日语没有
            // <4 字的实质提问，维持原闸。
            guard interviewLanguage == .chinese, q.count >= 3, core.count >= 2,
                  Self.zhLooksInterrogative(core) || core.hasSuffix("呢"),
                  !Self.zhShortFillers.contains(core) else { return false }
            return true
        }
        // 中文寒暄常带句中逗号（「好的，我明白了」），首尾 trim 够不到——查表前
        // 把句内顿逗一并去掉。日语表目本身不含标点，此归一化对日语无影响。
        let compact = String(core.filter { !"、，,　 ".contains($0) })
        return !Self.backchannels.contains(core) && !Self.backchannels.contains(compact)
    }

    /// 问句首尾要剥掉的标点（isMeaningfulQuestion / looksLikeCompletedPrompt 共用）。
    static let questionTrimSet = CharacterSet(charactersIn: "　 。．、，…!！?？")

    private static let backchannels: Set<String> = [
        "はい", "ええ", "うん", "そうですね", "なるほど", "なるほどですね",
        "了解", "オーケー", "わかりました", "承知しました", "いいですね",
        // 開始/終了の寒暄（単独で出たとき。本題が続けば settle で本題に連結される）
        "よろしくお願いします", "よろしくお願いいたします",
        "本日はよろしくお願いします", "それではよろしくお願いします",
        "ありがとうございます", "ありがとうございました",
        "お願いします", "失礼します", "失礼いたします",
        // 中文寒暄/附和（超过 4 字长度闸的那些；更短的被长度闸挡住）。
        // 不滤掉这些，每一句「好的，我明白了」都会取消在途生成、烧一次计费调用，
        // 并把垃圾回合写进 history 污染下一问的去重与 grounding。
        "好的好的", "对对对", "明白了", "我明白了", "好的我明白了", "好的明白了",
        "谢谢", "谢谢你", "谢谢您", "谢谢您的回答", "谢谢您的分享",
        "非常好", "很好", "没问题", "收到",
        "那我们开始吧", "我们开始吧", "那我们继续", "好的我们继续", "辛苦了",
    ]

    private func startTurn(question: String, speculative: Bool) {
        epoch += 1
        let myEpoch = epoch
        liveTask?.cancel(); routerTask?.cancel()
        // 用户可能正在回看旧答案。新问题来了就必须回到当下——面试里落后于此刻，
        // 比看不到上一条更致命。不还原快照：下面几行马上要写这一轮自己的问题与状态。
        answerHistory?.abandonReview()
        state = .generating
        liveBuffer = ""
        liveIsCommittedSource = false
        liveFlushScheduled = false
        liveClosed = false
        persistDeferred = false
        currentUsedSlotIDs = []
        self.speculative = speculative
        if speculative {
            specQuestion = question
            specStartsThisUtterance += 1
        } else {
            specQuestion = ""
            specStartsThisUtterance = 0
        }
        latency.turnStart(myEpoch, sttFinalNs: lastFinalNs, speculative: speculative)

        // 前ターンの答えはここでは消さない。新しい答えの先頭文が確定するまで（runRouter / runLive の
        // コミット点で上書き）画面に残し、考え中の一瞬だけ薄く表示する → 「答えが一度消える」体験を防ぐ。
        // 失敗時のみ failTurn でクリアしてエラーを見せる。
        model.errorDetail = nil
        model.intentLabel = ""
        model.question = question   // show what STT heard, so a mis-hear is caught before reading aloud
        model.status = .thinking
        model.message = .thinking

        currentQuestion = question
        currentSource = .live

        // Source 0：确定性事实即答。数字・条件系（希望年収 / 入社可能時期 / 語学スコア）
        // 命中就地上屏并**不启动**另外两路——命中即定稿，不存在被覆盖的问题。
        //
        // 刻意不受 `Settings.sendContextToLLM` 约束：那道门管的是「要不要把事实发到云端」，
        // 而这条路径全在本机、一个字节都不出网。关掉隐私开关的用户恰恰最需要这类即答，
        // 拿它当门会把功能反向关掉。
        if let facts = knowledge as? FactStore,
           let quick = FactQuickAnswer.answer(for: question, facts: facts,
                                              language: interviewLanguage) {
            // startTurn 本身非隔离，但本类的契约是「所有状态与 model 写入都串行在主队列上」
            // （见类型注释）；commitAnswer 已按该契约标了 @MainActor。
            MainActor.assumeIsolated {
                currentSource = .fact
                committedEpoch = myEpoch
                latency.markFirstReadable(epoch: myEpoch, kind: .fact)
                commitAnswer(quick, myEpoch: myEpoch)   // 内含 finishTurn：history / 回看 / 计时收尾
            }
            return
        }

        // 面接は連続した会話：hist は路由与 grounding 都要用（同一隐私门）。
        // 深掘り（「弊社ではどのように貢献できますか」接在ガクチカ回答之后）对孤立
        // 处理是致命的——路由会误命中字面相近的过去经历稿，grounding 也拉不进
        // 刚刚回答过的那条原稿。
        var hist = ""
        if Settings.sendContextToLLM {
            hist = historyText()   // same privacy gate as facts: opted out → no 流れ leaves the device
        }

        // Source A: router/cache — user script (preferred) + AI bank, if any candidates.
        let cands = routeCandidates(for: question)
        if !cands.isEmpty {
            routerTask = Task { [weak self] in
                await self?.runRouter(question: question, cands: cands, history: hist,
                                      myEpoch: myEpoch)
            }
        }

        // Source B: live generation — always, in parallel. Inject the prepared script as
        // grounding so a miss still produces an answer consistent with the user's wording.
        // Gated on the privacy toggle: when the user has opted out, the resume facts and
        // script are NOT sent to the cloud LLM (answers become generic).
        var ctx = ""
        if Settings.sendContextToLLM {
            ctx = liveContext(for: question)
        }
        let req = GenRequest(question: question, context: ctx, history: hist,
                             language: interviewLanguage)
        liveTask = Task { [weak self] in
            await self?.runLive(req, myEpoch: myEpoch)
        }
    }

    // MARK: - Source A: router / cache

    /// Question-addressable facts + script. Portrait pack when we have an index;
    /// otherwise the old dump + ranked script block (tests without a portrait).
    private func liveContext(for question: String) -> String {
        let prevQ = history.last?.q ?? ""
        if let portrait {
            let pinned = LLMRouter.isDeictic(question) ? lastUsedSlotIDs : []
            let packed = portrait.pack(question: question, previousQuestion: prevQ,
                                       pinnedIDs: pinned, language: interviewLanguage)
            currentUsedSlotIDs = packed.usedSlotIDs
            return packed.combined
        }
        var ctx = knowledge.context(for: question, language: interviewLanguage)
        let groundingQuery: String
        if prevQ.isEmpty {
            groundingQuery = question
        } else if LLMRouter.isDeictic(question) {
            groundingQuery = prevQ
        } else {
            groundingQuery = question + " " + prevQ
        }
        if let script = scriptStore?.contextBlock(for: groundingQuery,
                                                  language: interviewLanguage), !script.isEmpty {
            ctx += (ctx.isEmpty ? "" : "\n\n") + script
        }
        return ctx
    }

    /// Merge candidates for the Router: the user's hand-written script FIRST (so a tie
    /// resolves to the verbatim answer via Router's "lowest index" rule), then the AI bank.
    /// Skipped entirely when the user has opted out of sending context — the LLM router would
    /// otherwise receive the script/bank candidate questions.
    private func routeCandidates(for question: String) -> [BankEntry] {
        guard Settings.sendContextToLLM else { return [] }
        var cands = scriptStore?.candidates(for: question) ?? []
        // 预生成库整库带语言戳：与本场语言不一致就跳过——路由 prompt 明示「措辞不同
        // 也算 match」，日语库的候选在中文面试里是真实可命中的，命中即整段日语逐字
        // 上屏。用户手写原稿（scriptStore）不受此闸：写什么语言是用户自己的决定。
        if let bank {
            if Settings.answerBankLanguage == interviewLanguage {
                cands += bank.candidates(for: question)
            } else if !bank.isEmpty {
                // 示警只需「库非空」，不为一行日志付一次 ranked 全表扫描——
                // 语言不匹配恰恰是最需要省时的降级场景。
                NSLog("[router] answer bank is %@ but session is %@ — bank skipped (rebuild via 预生成回答)",
                      Settings.answerBankLanguage.rawValue, interviewLanguage.rawValue)
            }
        }
        return Array(cands.prefix(5))
    }

    private func runRouter(question: String, cands: [BankEntry], history: String,
                           myEpoch: Int) async {
        let decision: RouteDecision? = await {
            do {
                return try await router.route(question: question, candidates: cands,
                                              history: history)
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
                self.currentSource = self.sourceOfCachedAnswer(ans)
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
                self.currentSource = self.sourceOfCachedAnswer(ans)
                self.commitAnswer(ans, myEpoch: myEpoch)
            } else {
                // Diagnosability: before this log existed, a lost race was indistinguishable
                // from a router miss in the field (the "answer isn't my script" reports).
                NSLog("[router] late hit (turn %d): answer already settled — 原稿 dropped", myEpoch)
            }
        }
    }

    /// 命中的这条是用户手写的原稿，还是 AI 预生成的答案库？复盘页要分开呈现：
    /// bank 也算「准备到了」，但内容是模板化的，命中率高不代表回答有竞争力。
    private func sourceOfCachedAnswer(_ answer: String) -> AnswerSource {
        if scriptStore?.active?.entries.contains(where: { $0.answer == answer }) == true { return .script }
        return .bank
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
                    // normalize 与下游的 CTFrame 量高都是对整段 buffer 的 O(n) 全量
                    // 重跑——逐 token 执行在长答案上是主线程 O(n²)。「已有 flush 在队
                    // 列里就不再排」只在主线程堵住时才合并，常态 SSE（每 20-40ms 一个
                    // token、主线程空闲）下一个字都省不了；真正封顶靠时间维度节流：
                    // 提交后每 50ms 至多刷一次（≪ 渲染层 0.18s 逐字淡入，不可感知）。
                    // 提交前保持即时——首句上屏在关键路径上，一毫秒都不多等。
                    guard !self.liveFlushScheduled else { return }
                    self.liveFlushScheduled = true
                    let delay: TimeInterval = self.liveIsCommittedSource ? 0.05 : 0
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                        guard let self else { return }
                        MainActor.assumeIsolated { self.flushLive(myEpoch) }
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

    /// 合批后的上屏刷新（主队列）。提交判定从 delta 回调移到这里：commit 时机最多
    /// 晚一个节流周期（≤50ms），远小于渲染层 0.18s 的逐字淡入。
    @MainActor private func flushLive(_ myEpoch: Int) {
        // 过期 flush 不碰新一轮的调度标志——startTurn 已为新轮复位。
        guard myEpoch == epoch else { return }
        liveFlushScheduled = false
        // 终态守卫：finishLive/failTurn 已收束本轮（含空正文与未提交失败的错误分支，
        // 它们不走 finishTurn、state 不会变 .presenting，只有这面旗帜能挡住迟到的 flush）。
        guard !liveClosed else { return }
        if committedEpoch == myEpoch && !liveIsCommittedSource { return } // cache won / late-hit 换稿
        if !liveIsCommittedSource {
            guard hasSpeakableOpening(liveBuffer) else { return }
            markLiveCommitted(myEpoch)
        }
        model.answer = SpokenAnswerFormatter.normalize(liveBuffer)
    }

    /// live 流赢下（或收尾时兜底提交）本轮的五连写，flushLive / finishLive 共用。
    @MainActor private func markLiveCommitted(_ myEpoch: Int) {
        committedEpoch = myEpoch
        liveIsCommittedSource = true
        latency.markFirstReadable(epoch: myEpoch, kind: .live)
        model.status = .streaming
        model.message = .suggesting
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
    /// from blocking the UI indefinitely. Chinese first sentences often wait 20–40
    /// characters for `。`, so a shorter length fallback lets the candidate start.
    func hasSpeakableOpening(_ text: String) -> Bool {
        Self.hasSpeakableOpening(text, language: interviewLanguage)
    }

    static func hasSpeakableOpening(_ text: String, language: InterviewLanguage) -> Bool {
        let boundaries = CharacterSet(charactersIn: "。！？!?\n")
        let punctuated = text.rangeOfCharacter(from: boundaries) != nil
        switch language {
        case .chinese:
            return (text.count >= 8 && punctuated) || text.count >= 24
        case .japanese:
            return (text.count >= 12 && punctuated) || text.count >= 90
        }
    }

    @MainActor private func finishLive(_ myEpoch: Int) {
        guard myEpoch == epoch else { return }
        liveClosed = true   // 此后任何迟到的 flushLive 一律作废（含下方空正文错误分支）
        if committedEpoch != myEpoch {
            // very short answer that never tripped the commit threshold — commit now.
            markLiveCommitted(myEpoch)
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
        state = .presenting
        model.status = .presenting
        model.message = .completed
        // 投机轮可以上屏，但落史必须等终稿确认——否则半截 interim 命中事实即答
        // 后，面试官把问句说完会再开一轮，假回合已经进了 SessionStore 且无撤回路径。
        if speculative {
            persistDeferred = true
            return
        }
        persistTurn(myEpoch)
    }

    @MainActor private func persistTurn(_ myEpoch: Int) {
        guard myEpoch == epoch else { return }
        latency.turnEnd(myEpoch)
        recordHistory()
        // 全文入回看记录。传 epoch 而不是问题文本：迟到的原稿命中会让同一轮再次定稿，
        // 按 epoch 就地更新才不会把同一轮堆成两条（面试官重复同一问题时也不会误合并）。
        answerHistory?.record(epoch: myEpoch, question: currentQuestion,
                              answer: model.answer, intent: model.intentLabel)
        onTurnRecorded?(currentQuestion, model.answer, currentSource)
        if !currentUsedSlotIDs.isEmpty { lastUsedSlotIDs = currentUsedSlotIDs }
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
        // 标签必须与 Prompts.user 里解释这两个标签的文案同语言（中文版是「面试官/建议回答」）。
        let (qLabel, aLabel): (String, String)
        switch interviewLanguage {
        case .japanese: (qLabel, aLabel) = ("面接官", "回答案")
        case .chinese: (qLabel, aLabel) = ("面试官", "建议回答")
        }
        return history.suffix(4).map { "\(qLabel): \($0.q)\n\(aLabel): \($0.a)" }.joined(separator: "\n\n")
    }

    @MainActor private func failTurn(_ myEpoch: Int, error: Error) {
        guard myEpoch == epoch else { return }
        liveClosed = true   // 同 finishLive：错误态落地后，迟到的 flushLive 不许改写它
        guard committedEpoch != myEpoch else {
            guard liveIsCommittedSource else {
                // cache 已赢下本轮：live 流的失败与屏上的原稿无关，且 finishTurn 已经
                // 跑过——再跑一遍会给完好的原稿挂「可能不完整」，并把同一轮压成
                // history 双条、SessionStore 重复行、延迟账双记。
                NSLog("[turn] live stream failed after cache commit (turn %d) — ignored", myEpoch)
                return
            }
            // 已经上屏之后才失败（网络中途断开）。旧实现在这里直接 return，回合永远停在
            // .streaming：用户对着半截答案，状态行一直显示「生成中」，面板不折叠，
            // 该回合也不进 history（下一问的深掘去重少一环），LatencyMonitor 还会漏账。
            // 正确的收尾是把已有内容定格为完成态，并附上「可能不完整」的提示。
            NSLog("[turn] stream failed after commit (turn %d): %@",
                  myEpoch, String(describing: error))
            model.answer = SpokenAnswerFormatter.normalize(liveBuffer)
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
