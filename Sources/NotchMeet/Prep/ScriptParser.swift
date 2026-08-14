import Foundation

/// Parses a user-written interview script (面接原稿) into `BankEntry` items.
///
/// The parser intentionally stays offline and deterministic, but accepts the formats
/// people commonly paste from Markdown, Word, Notion and interview-prep documents:
/// headings, Q/A labels, numbered topics, bracketed topics, plain question lines and
/// two-column Markdown tables. Answers are otherwise kept verbatim.
enum ScriptParser {
    /// 只有显式开启时才把用户稿件的标题原文写进系统日志（同 TurnManager 的 FI_STT_DEBUG）。
    static let parseDebug = ProcessInfo.processInfo.environment["FI_PARSE_DEBUG"] == "1"

    static func parse(_ text: String) -> [BankEntry] {
        let lines = normalizedLines(text)
        var entries: [BankEntry] = []
        var heading: String?
        var headingLevel: Int?          // ATX/Setext level of the current heading (nil = label/plain)
        var parent: (text: String, level: Int)?   // empty ATX heading followed by deeper variants
        var buffer: [String] = []
        let titleIndex = documentTitleIndex(lines)

        func append(question: String, answer: String) {
            let q = cleanQuestion(question)
            let a = cleanAnswer(answer)
            guard !q.isEmpty, !a.isEmpty else { return }
            entries.append(BankEntry(id: "script-\(entries.count + 1)",
                                     intent: q, question: q, answer: a, locked: true))
        }

        func flush(quiet: Bool = false) {
            guard let heading else {
                buffer.removeAll(keepingCapacity: true)
                return
            }
            if !quiet, cleanAnswer(buffer.joined(separator: "\n")).isEmpty {
                // Two headings in a row: usually the document title, but log it — a
                // dropped heading with a real question would silently lose an entry.
                //
                // 标题原文是用户内容（公司名、个人题目），与转录原文同一条策略：
                // NSLog 默认 public，会进 /var/db/diagnostics 保留数天、随 sysdiagnose
                // 外泄，而「删除本地数据」清不掉系统日志。默认只记长度——「有没有丢条目」
                // 照样看得出来，要看是哪一条再开 FI_PARSE_DEBUG=1。
                if Self.parseDebug { NSLog("[parser] heading without answer dropped: %@", heading) }
                else { NSLog("[parser] heading without answer dropped (%d chars)", heading.count) }
            }
            append(question: heading, answer: buffer.joined(separator: "\n"))
            buffer.removeAll(keepingCapacity: true)
        }

        var index = 0
        while index < lines.count {
            let line = lines[index]

            // A Markdown table stores the question and answer on the same line.
            if let row = tableEntry(line) {
                flush()
                heading = nil
                append(question: row.question, answer: row.answer)
                index += 1
                continue
            }

            let previousIsBlank = index == 0 || lines[index - 1].trimmed.isEmpty
            let nextLine = index + 1 < lines.count ? lines[index + 1] : nil
            // 逆質問の回答は準備した質問文そのもの — その中の質問行を新しい見出しに
            // 昇格させると項目が分裂する。明示的な見出し（#/ラベル）だけ許す。
            let allowUnlabelled = !(heading.map(isReverseQuestionTopic) ?? false)
            if let found = headingText(line,
                                       nextLine: nextLine,
                                       previousIsBlank: previousIsBlank,
                                       allowUnlabelledQuestion: allowUnlabelled) {
                // The document title (single H1 over deeper sections) is not a Q&A entry;
                // its buffer (metadata lines) is dropped with it.
                if index == titleIndex {
                    flush()
                    heading = nil
                    if isSetextUnderline(nextLine ?? "") { index += 1 }
                    index += 1
                    continue
                }
                // 「## 自己紹介」(空) → 「### 30秒版」「### 1分版」: variant sub-headings of
                // an empty parent inherit its topic, or 自己紹介 becomes unreachable.
                let composing = found.atxLevel != nil && heading != nil
                    && cleanAnswer(buffer.joined(separator: "\n")).isEmpty
                    && headingLevel != nil && found.atxLevel! > headingLevel!
                if composing { parent = (heading!, headingLevel!) }
                flush(quiet: composing)
                if let level = found.atxLevel, let p = parent, level <= p.level { parent = nil }
                if let level = found.atxLevel, let p = parent, level > p.level {
                    heading = p.text + "・" + found.text
                } else {
                    heading = found.text
                }
                headingLevel = found.atxLevel ?? headingLevel
                // The next line is a Setext underline (`---` / `===`), not answer text.
                if let nextLine, isSetextUnderline(nextLine) { index += 1 }
            } else if !isMarkdownSeparator(line), !isKeywordMemo(line) {
                buffer.append(line)
            }
            index += 1
        }
        flush()
        return entries
    }

    /// プロンプター用の備忘行（`▼キーワード: …`）— 読み上げ原稿には混ぜない。
    private static func isKeywordMemo(_ line: String) -> Bool {
        line.trimmed.hasPrefix("▼")
    }

    /// The integrated-doc convention opens with a single `# タイトル` above `##` sections;
    /// that H1 (and its metadata lines) is a title, not a question — but only when it
    /// does not itself read as a topic/question (`# 自己紹介` docs keep working).
    private static func documentTitleIndex(_ lines: [String]) -> Int? {
        var firstH1: (index: Int, text: String)?
        var h1Count = 0
        var hasDeeper = false
        for (i, line) in lines.enumerated() {
            guard let match = capture(line.trimmed, pattern: #"^(#{1,6})\s+(.+?)(?:\s+#+)?$"#,
                                      group: 2),
                  let hashes = capture(line.trimmed, pattern: #"^(#{1,6})\s"#) else { continue }
            if hashes.count == 1 {
                h1Count += 1
                if firstH1 == nil { firstH1 = (i, match) }
            } else {
                hasDeeper = true
            }
        }
        guard h1Count == 1, hasDeeper, let title = firstH1,
              !isTopicOrQuestion(cleanQuestion(stripQuestionLabel(title.text))) else { return nil }
        return title.index
    }

    // MARK: - Heading recognition

    private static func isReverseQuestionTopic(_ heading: String) -> Bool {
        let key = compact(heading).lowercased()
        return ["逆質問", "何か質問", "反向提问", "questionsforus"].contains { key.contains($0) }
    }

    private static func headingText(_ line: String,
                                    nextLine: String?,
                                    previousIsBlank: Bool,
                                    allowUnlabelledQuestion: Bool = true)
        -> (text: String, atxLevel: Int?)? {
        var text = line.trimmed
        guard !text.isEmpty else { return nil }

        // Markdown ATX headings. Requiring whitespace after `#` avoids treating hashtags
        // inside an answer as a new question. Q/深掘り labels and list numbers inside the
        // heading are stripped so the stored question is the actual question text.
        if let match = capture(text, pattern: #"^#{1,6}\s+(.+?)(?:\s+#+)?$"#) {
            let level = text.prefix(while: { $0 == "#" }).count
            return (cleanQuestion(stripQuestionLabel(match)), level)
        }

        // Markdown Setext headings:
        //   志望動機
        //   --------
        if let nextLine, isSetextUnderline(nextLine), text.count <= 100 {
            let level = nextLine.trimmed.first == "=" ? 1 : 2
            return (cleanQuestion(stripQuestionLabel(text)), level)
        }

        text = unwrappedEmphasis(text)

        // Explicit Q / question / interviewer / follow-up labels, with optional numbers.
        for pattern in explicitPatterns {
            if let match = capture(text, pattern: pattern, caseInsensitive: true) {
                return (cleanQuestion(match), nil)
            }
        }

        // Strong standalone wrappers frequently used in Word / Notion documents.
        let wrappers: [(Character, Character)] = [("【", "】"), ("［", "］"), ("[", "]")]
        if let first = text.first, let last = text.last,
           wrappers.contains(where: { $0.0 == first && $0.1 == last }), text.count <= 100 {
            return (cleanQuestion(String(text.dropFirst().dropLast())), nil)
        }

        // Numbered headings, but only when the remainder genuinely resembles a topic or
        // question. This keeps `1. 売上を分析した` inside an answer intact. The question
        // branch respects allowUnlabelledQuestion: a 逆質問 answer IS a numbered list of
        // questions and must not be split (実稿で5問が1断片に潰れた).
        if let match = capture(text,
                               pattern: #"^(?:[0-9０-９]{1,3}[.．、:：)）]|[①②③④⑤⑥⑦⑧⑨⑩⑪⑫⑬⑭⑮⑯⑰⑱⑲⑳])\s*(.+)$"#),
           isKnownTopic(match.trimmingCharacters(in: CharacterSet(charactersIn: ":：")))
               || (allowUnlabelledQuestion && looksLikeQuestion(match)) {
            return (cleanQuestion(match), nil)
        }

        // A short standalone canonical topic such as `志望動機` or `自己PR：`.
        let withoutTrailingColon = text.trimmingCharacters(in: CharacterSet(charactersIn: ":："))
        if isKnownTopic(withoutTrailingColon) {
            return (cleanQuestion(withoutTrailingColon), nil)
        }

        // Finally accept an unlabelled question sentence when it starts a paragraph.
        // Paragraph position is an important false-positive guard for prose answers.
        if allowUnlabelledQuestion, previousIsBlank, text.count <= 120, looksLikeQuestion(text) {
            return (cleanQuestion(text), nil)
        }
        return nil
    }

    private static func isTopicOrQuestion(_ text: String) -> Bool {
        isKnownTopic(text.trimmingCharacters(in: CharacterSet(charactersIn: ":："))) || looksLikeQuestion(text)
    }

    private static func isKnownTopic(_ value: String) -> Bool {
        knownTopics.contains(compact(value).lowercased())
    }

    /// 话题短行白名单。中日两份 `Intents.list` 是种子——预生成回答按它出标题，用户照抄
    /// 当话题行写稿，这里认不出就等于稿子白准备（且改 Intents 不改这里的漂移是静默的，
    /// 手抄副本在写下「已对齐」的同一次提交里就漏了 5 条）。种子之外只保留少量口语变体；
    /// 通用四字名词（项目经历/团队合作/兴趣爱好…之外的自造项）不要加：本分支没有
    /// `previousIsBlank` 段落护栏，太泛的词会把答案正文里的小标签行提升成标题、劈开条目。
    private static let knownTopics: Set<String> = {
        var topics: Set<String> = [
            "自己紹介", "自己pr", "志望動機", "志望理由", "応募理由", "ガクチカ",
            "学生時代に力を入れたこと", "学生時代に頑張ったこと", "強み", "弱み",
            "長所", "短所", "逆質問", "就活の軸", "企業選びの軸", "キャリアプラン",
            "将来像", "研究内容", "ゼミ", "アルバイト", "趣味", "特技", "挫折経験",
            "失敗経験", "成功体験", "チーム経験", "リーダー経験", "他社選考状況",
            "希望職種", "入社後にしたいこと", "転勤について", "自己评价", "自我介绍",
            "应聘动机", "志愿理由", "优点", "缺点", "反向提问", "careerplan",
            "selfintroduction", "motivation", "strengths", "weaknesses",
            // 中文口语变体（Intents 正名之外用户常写的形）。
            "学生经历", "挫折经历", "期望薪资", "到岗时间",
        ]
        for intent in Intents.list(for: .japanese) + Intents.list(for: .chinese) {
            topics.insert(compact(intent).lowercased())
        }
        return topics
    }()

    /// A line counts as a question ONLY when it ENDS like one (…か／？／依頼形) or
    /// opens with an interrogative marker in Chinese. Substring signals (なぜ/どのよう
    /// appearing anywhere) mis-fired on real scripts: answer paragraphs that merely
    /// mention them were promoted to headings, destroying the entry they belonged to.
    private static func looksLikeQuestion(_ value: String) -> Bool {
        let text = value.trimmed
        let core = text.trimmingCharacters(in: CharacterSet(charactersIn: "　 。．、…!！?？"))
        // 挨拶・結びで終わる行は質問ではない。全文一致ではなく末尾一致で判定する：
        // 回答の結び段落は「〜と考えています。本日はどうぞよろしくお願いいたします。」の
        // ように前文を伴うのが普通で、お願いします 接尾だけ見ると依頼形と誤爆する。
        let closingTails = ["よろしくお願いします", "よろしくお願いいたします",
                            "ありがとうございます", "ありがとうございました"]
        guard !closingTails.contains(where: core.hasSuffix) else { return false }
        if text.hasSuffix("?") || text.hasSuffix("？") { return true }
        if core.hasSuffix("か") { return true }        // …ですか／…でしょうか／…のか
        // 「呢」刻意不收：它同时是延续语气助词，中文答案正文的段首句常以它收尾
        // （「要说最大的收获呢」），后缀判定会把该行提升成标题、腰斩条目——与上方
        // 注释记录的旧误爆同型。「吗」几乎专职疑问，保留。
        let requestTails = ["ください", "下さい", "お願いします", "お願いいたします",
                            "是什么", "吗"]
        if requestTails.contains(where: core.hasSuffix) { return true }
        // 中文问题行常以祈使动词开头（「谈谈你的职业规划」「介绍一下你自己」）。
        // 祈使前缀锚定第二人称/「自己」：答案正文段落也会以「说说我自己的体会…」
        // 起头，无锚定的裸动词前缀会把它提升成标题。
        let interrogativePrefixes = ["请", "为什么", "如何", "谈谈你", "说说你", "讲讲你",
                                     "聊聊你", "介绍一下你", "介绍一下自己",
                                     "描述一下你", "分享一下你"]
        return interrogativePrefixes.contains(where: core.hasPrefix)
    }

    /// Q1: / 深掘り: … labels — shared by explicit label lines and (after F1) headings.
    private static let explicitPatterns = [
        #"^(?:Q(?:uestion)?|質問|問題|问题|问|問|面接官)\s*[0-9０-９]*\s*[:：.．、)）]\s*(.+)$"#,
        #"^(?:質問|問題|问题|问|問)\s*[0-9０-９]+\s+(.+)$"#,
        #"^(?:深掘り|深堀り|追加質問|追問|追问|Follow[- ]?up)\s*[0-9０-９]*\s*[:：.．、)）]\s*(.+)$"#,
    ]

    private static func stripQuestionLabel(_ raw: String) -> String {
        var text = unwrappedEmphasis(raw.trimmed)
        // `## 1. 自己紹介` — the list number is structure, not question text. Whitespace
        // after the punctuation is required so `1.5倍成長` style openings stay intact.
        if let match = capture(text, pattern: #"^[0-9０-９]{1,3}[.．、:：)）]\s+(.+)$"#) {
            text = match
        }
        for pattern in explicitPatterns {
            if let match = capture(text, pattern: pattern, caseInsensitive: true) { return match }
        }
        return text
    }

    // MARK: - Answer cleanup and table support

    private static func cleanAnswer(_ raw: String) -> String {
        var body = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return "" }

        // Drop an answer label from the first non-empty line only. The remaining answer
        // stays verbatim, including bullets and paragraph breaks.
        body = replacingFirstMatch(
            in: body,
            pattern: #"^(?:A(?:nswer)?|回答(?:例|内容)?|答え?|答案|应答)\s*[0-9０-９]*\s*[:：.．、)）]\s*"#,
            caseInsensitive: true
        )
        return body.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func tableEntry(_ line: String) -> (question: String, answer: String)? {
        let text = line.trimmed
        guard text.hasPrefix("|"), text.hasSuffix("|") else { return nil }
        let cells = text.dropFirst().dropLast().split(separator: "|", omittingEmptySubsequences: false)
            .map { String($0).trimmed }
        guard cells.count >= 2 else { return nil }
        let question = cells[0]
        let answer = cells[1...].joined(separator: " | ")
        let headerNames: Set<String> = ["質問", "问题", "問題", "question", "q"]
        guard !headerNames.contains(question.lowercased()),
              !question.allSatisfy({ "-: ".contains($0) }),
              !answer.allSatisfy({ "-: ".contains($0) }),
              !question.isEmpty, !answer.isEmpty else { return nil }
        return (cleanQuestion(question), cleanAnswer(answer))
    }

    // MARK: - Small string helpers

    private static func normalizedLines(_ text: String) -> [String] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{feff}", with: "")
            .components(separatedBy: "\n")
        // Whole-line HTML comments (`<!-- … -->`, possibly spanning lines) are authoring
        // notes, never Q&A content. Inline comments mixed with prose are left alone.
        var out: [String] = []
        var inComment = false
        for line in lines {
            let t = line.trimmed
            if inComment {
                if t.hasSuffix("-->") || t.contains("-->") { inComment = false }
                continue
            }
            if t.hasPrefix("<!--") {
                if !t.contains("-->") { inComment = true }
                continue
            }
            out.append(line)
        }
        return out
    }

    private static func cleanQuestion(_ raw: String) -> String {
        unwrappedEmphasis(raw.trimmed)
            .trimmingCharacters(in: CharacterSet(charactersIn: " \t#"))
    }

    private static func unwrappedEmphasis(_ raw: String) -> String {
        var text = raw.trimmed
        for marker in ["**", "__"] where text.hasPrefix(marker) && text.hasSuffix(marker) && text.count > marker.count * 2 {
            text = String(text.dropFirst(marker.count).dropLast(marker.count)).trimmed
            break
        }
        return text
    }

    private static func compact(_ text: String) -> String {
        text.components(separatedBy: .whitespacesAndNewlines).joined()
    }

    private static func isSetextUnderline(_ line: String) -> Bool {
        let text = line.trimmed
        guard text.count >= 3 else { return false }
        return text.allSatisfy { $0 == "=" } || text.allSatisfy { $0 == "-" }
    }

    private static func isMarkdownSeparator(_ line: String) -> Bool {
        let text = line.trimmed
        guard text.count >= 3 else { return false }
        return text.allSatisfy { "-*_ ".contains($0) }
    }

    private static func capture(_ text: String,
                                pattern: String,
                                caseInsensitive: Bool = false,
                                group: Int = 1) -> String? {
        let options: NSRegularExpression.Options = caseInsensitive ? [.caseInsensitive] : []
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: fullRange), match.numberOfRanges > group,
              let range = Range(match.range(at: group), in: text) else { return nil }
        return String(text[range]).trimmed
    }

    private static func replacingFirstMatch(in text: String,
                                            pattern: String,
                                            caseInsensitive: Bool = false) -> String {
        let options: NSRegularExpression.Options = caseInsensitive ? [.caseInsensitive] : []
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return text }
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, range: fullRange, withTemplate: "")
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
