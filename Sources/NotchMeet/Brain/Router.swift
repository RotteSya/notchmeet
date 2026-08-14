import Foundation

struct RouteDecision {
    let intent: String
    let matchedAnswer: String?   // non-nil only on a confident cache hit
}

/// Decides intent + whether a cached answer truly matches (PLAN §7). Conservative:
/// when unsure → no match (live generation handles it). NullRouter always misses.
///
/// `history` 是直前几轮的「面接官の質問＋提示した回答」摘要（可为空）。没有它，路由对
/// 深掘り 是盲的：实测中「学生時代…」答完后接的「弊社ではどのように貢献できますか」
/// 被当成孤立问题，靠「貢献」二字误命中了一条**过去经历**的原稿——上下文依赖的追问，
/// 孤立的准备稿读出来就是答非所问。
protocol Router: AnyObject {
    func route(question: String, candidates: [BankEntry], history: String) async throws -> RouteDecision
}

extension Router {
    func route(question: String, candidates: [BankEntry]) async throws -> RouteDecision {
        try await route(question: question, candidates: candidates, history: "")
    }
}

final class NullRouter: Router {
    func route(question: String, candidates: [BankEntry], history: String) async throws -> RouteDecision {
        RouteDecision(intent: "", matchedAnswer: nil)
    }
}

/// Single fast LLM call returns BOTH the intent and the match index (merged, per
/// §7 / §14.3 — no serial two-hop). Biased to answer `null` unless certain.
final class LLMRouter: Router {
    /// The match criterion is ANSWERABILITY, not sameness: interviewers never phrase a
    /// question exactly like the script heading (「就活の軸を教えてください」 vs 稿の
    /// 「就職活動の軸」). "同じことを聞いている" made the small model reject nearly every
    /// paraphrase — the field reports of "answer isn't my script" trace back to it.
    /// Uncertainty still means null: a wrong verbatim answer read aloud is worse than a
    /// grounded live one.
    static func systemPrompt(language: InterviewLanguage = Settings.interviewLanguage) -> String {
        switch language {
        case .japanese: systemPromptJa()
        case .chinese: systemPromptZh()
        }
    }

    private static func systemPromptJa() -> String {
        let intentList = Intents.list(for: .japanese).joined(separator: "、")
        return """
        あなたは面接質問のルーターです。出力は JSON のみ。説明禁止。
        形式: {"intent":"<候補意図>","match":<候補番号 or null>}
        ルール:
        - intent は次から最も近いものを1つ: \(intentList)
        - match は、その候補の準備済み回答を『この質問への返答としてそのまま読み上げて成立する』場合のみその番号。質問の言い回しが違っても、聞かれている中身に回答が正面から答えていれば match とする。
        - 語彙が違っても指す内容が同じなら match（例: ビザ＝在留資格、うち・御社＝当社、転勤＝勤務地）。
        - 時間軸を合わせる: 入社後・将来どう貢献/活躍できるかを聞く質問に、過去の経験を述べるだけの回答は match ではない。逆に、過去の経験を聞く質問に将来の抱負だけの回答も match ではない。
        - 質問に「それ・その・先ほどの」など直前の回答内容を指す語がある場合は、次の手順で判定する:
          手順1: 直前のやり取りの回答が語っている経験・題材を特定する（例: MBAでの学び直し）。
          手順2: 候補の回答本文が語っている経験・題材を特定する（例: システム導入のずれ）。
          手順3: 両者が同一の経験なら match、**別の経験なら必ず null**。回答の形（将来への活かし方を述べる等）が質問に合っていても、別の経験を語る回答を読み上げれば話のすり替えになる。
        - 注意: 候補の質問文に含まれる「それ・その」は、その候補が書かれた別の文脈を指す。質問文どうしが似ていることは match の根拠にならない——判定は必ず回答本文の中身で行う。
        - 直前の文脈に接続しないと成立しない深掘り質問に、合う候補がなければ null（live 生成が文脈を見て答える）。
        - 面接官が「あなたから何か質問は？」型の質問をした場合は、準備した逆質問の候補が該当する。
        - 複数の候補が該当する場合は、最も小さい番号を選ぶ（ユーザー作成の原稿を優先）。
        - 回答がズレる・部分的にしか答えない・自信がない場合は match は必ず null。
        """
    }

    /// 中文面试的同一套路由规则。判据仍是「可答性」而非「同题性」，且不确定必须 null——
    /// 把别人的准备稿念错，比现场生成慢一点严重得多（与日语版同一取舍）。
    private static func systemPromptZh() -> String {
        let intentList = Intents.list(for: .chinese).joined(separator: "、")
        return """
        你是面试问题的路由器。只输出 JSON，禁止解释。
        格式: {"intent":"<候选意图>","match":<候选编号 or null>}
        规则:
        - intent 从以下选最接近的一个: \(intentList)
        - 只有当该候选的准备好回答『作为对这个问题的回应直接照着念出来能成立』时，match 才填其编号。问法措辞不同没关系，只要回答正面回应了被问的内容就算 match。
        - 用词不同但所指相同也算 match（例: 签证＝在留资格、你们公司＝贵司、外派＝调动工作地点）。
        - 对齐时间轴: 问「入职后、将来能做什么贡献」的问题，只讲过去经历的回答不算 match；反过来，问过去经历的问题，只讲将来抱负的回答也不算 match。
        - 问题里有「它、这个、刚才的、你刚才说的」等指向上一条回答内容的词时，按以下步骤判定:
          步骤1: 确认上一轮对话的回答讲的是哪段经历、哪个题材（例: 读 MBA 重新学习）。
          步骤2: 确认候选回答正文讲的是哪段经历、哪个题材（例: 系统上线延期）。
          步骤3: 两者是同一段经历才 match，**不同经历必须 null**。即使回答的形式（讲将来如何运用等）与问题相合，念出讲另一段经历的回答就是偷换话题。
        - 注意: 候选问题文里的「它、这个」指的是那条候选被写下时的另一个语境。问题文相似不构成 match 的依据——判定必须依据回答正文的内容。
        - 不衔接上文就不成立的追问，没有合适候选就 null（live 生成会看着上下文回答）。
        - 面试官问「你有什么想问我们的吗」这类问题时，准备好的反向提问候选适用。
        - 多个候选都适用时，选编号最小的（用户自写的原稿优先）。
        - 回答对不上、只回答了一部分、或没有把握时，match 必须是 null。
        """
    }

    /// Judging answerability requires SEEING the answer: each candidate carries the
    /// opening of its prepared answer, capped so five candidates stay a few hundred
    /// chars (prompt-processing cost is negligible against the 3s SLA).
    /// 100 字而非 60：经历一致性规则要求模型能看出「这条稿讲的是哪段经历」，
    /// 60 字常常还没露出经历的具体内容。
    static func candidateBlock(_ candidates: [BankEntry],
                               language: InterviewLanguage = Settings.interviewLanguage) -> String {
        let (qLabel, aLabel) = language == .chinese ? ("问题", "回答开头") : ("質問", "回答冒頭")
        var cand = ""
        for (i, e) in candidates.enumerated() {
            let head = e.answer.count > 100 ? e.answer.prefix(100) + "…" : Substring(e.answer)
            cand += "[\(i)] \(qLabel): \(e.question)\n    \(aLabel): \(head)\n"
        }
        return cand
    }

    func route(question: String, candidates: [BankEntry], history: String) async throws -> RouteDecision {
        let language = Settings.interviewLanguage
        let cand = Self.candidateBlock(candidates, language: language)
        var user = ""
        if !history.isEmpty {
            user += language == .chinese ? "上一轮对话:\n\(history)\n\n" : "直前のやり取り:\n\(history)\n\n"
        }
        if language == .chinese {
            user += "问题: \(question)\n\n候选:\n\(cand.isEmpty ? "(无)" : cand)"
        } else {
            user += "質問: \(question)\n\n候補:\n\(cand.isEmpty ? "(なし)" : cand)"
        }
        let raw = try await FastLLM.complete(system: Self.systemPrompt(language: language),
                                             user: user, maxTokens: 80)
        let decision = parse(raw, candidates: candidates)
        return Self.vetoingContextMismatch(decision, question: question, history: history)
    }

    // MARK: - 经历一致性护栏（确定性，不交给模型）

    /// 指代型追问的答案掉包否决。
    ///
    /// 实机事故：「それを弊社で生かすことができますか」命中了绑定在**另一段经历**上的
    /// 桥接稿。prompt 规则连续两轮迭代都被小模型无视（3/3 误命中）——候选标题
    /// 「その学びは仕事でどう活きますか」与问句在问句层面几乎同文，问句相似度的
    /// 强信号淹没了一切内容比对指令。所以这道判定不留给模型：问句含指代词、且命中稿
    /// 与直前对话的内容词重叠不足时，在代码里把 match 否决成 null。
    ///
    /// 误杀的代价是温和的（live 生成拿着真实 history + grounding 桥接，grounding 的
    /// 排序已混入上一问）；漏放的代价是把别的经历当刚才的读出来。不对称，偏向否决。
    static func vetoingContextMismatch(_ d: RouteDecision, question: String,
                                       history: String) -> RouteDecision {
        guard let answer = d.matchedAnswer, !history.isEmpty, isDeictic(question) else { return d }
        let shared = contentWords(answer).intersection(contentWords(history))
        guard shared.count < 2 else { return d }
        NSLog("[router] deictic question, matched answer shares %d content word(s) with history — veto",
              shared.count)
        return RouteDecision(intent: d.intent, matchedAnswer: nil)
    }

    /// 问句是否指代直前的回答内容。「それでは/それじゃ」是话轮开场语，不算指代——
    /// 只认对象格/主格的それ与明确回指的表达。中文标记同理：「那么/那我们」是开场语，
    /// 不进列表；只认「刚才/刚刚/你说的那」这类明确回指。日中标记并存无害——
    /// 日语问句里不会出现「刚才」，反之亦然。
    static func isDeictic(_ question: String) -> Bool {
        let markers = ["それを", "それが", "それって", "その経験", "その学び", "その強み",
                       "その話", "先ほどの", "さっきの", "今の話",
                       "刚才", "刚刚", "刚提到", "你说的那", "那段经历", "那个经历", "这段经历"]
        return markers.contains(where: question.contains)
    }

    /// 内容词：连续 2 字以上的汉字串（現場/効率/分析…）、片假名串（データ/チーム…）、
    /// 拉丁串（MBA/AI…）。平假名基本是语法成分，全部丢弃——它们的重叠没有内容含义。
    static func contentWords(_ text: String) -> Set<String> {
        enum Kind { case kanji, katakana, latin, other }
        func kind(_ s: UnicodeScalar) -> Kind {
            switch s.value {
            case 0x3400...0x4dbf, 0x4e00...0x9fff: return .kanji
            case 0x30a0...0x30ff: return .katakana
            case 0x41...0x5a, 0x61...0x7a, 0x30...0x39: return .latin
            default: return .other
            }
        }
        var words = Set<String>()
        var run = ""
        var runKind = Kind.other
        for s in text.unicodeScalars {
            let k = kind(s)
            if k == runKind, k != .other {
                run.unicodeScalars.append(s)
            } else {
                if run.count >= 2, runKind != .other { words.insert(run.lowercased()) }
                run = k == .other ? "" : String(s)
                runKind = k
            }
        }
        if run.count >= 2, runKind != .other { words.insert(run.lowercased()) }
        return words
    }

    func parse(_ raw: String, candidates: [BankEntry]) -> RouteDecision {
        // tolerate code fences / surrounding text — extract the first {...}
        guard let lo = raw.firstIndex(of: "{"), let hi = raw.lastIndex(of: "}"),
              let data = String(raw[lo...hi]).data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return RouteDecision(intent: "", matchedAnswer: nil)
        }
        let intent = (o["intent"] as? String) ?? ""
        // Small domestic models occasionally quote the index ({"match":"0"}) — a typed
        // miss here silently discards the user's verbatim answer, so accept both.
        let idx = (o["match"] as? Int) ?? (o["match"] as? String).flatMap(Int.init)
        var answer: String?
        if let idx, idx >= 0, idx < candidates.count {
            answer = candidates[idx].answer
        }
        return RouteDecision(intent: intent, matchedAnswer: answer)
    }
}
