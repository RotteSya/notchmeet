import Foundation

/// 简历 → FactSheet 的受限抽取（模块 C 的抽取层）。
///
/// 与 `ScriptImporter` 同族但约束级别不同：稿件要逐字照念，所以答案必须是原文子串；
/// 简历抽取本质是**结构化重述**（把段落重述为角色/时段/动作/成果），严格子串会让
/// 抽取率归零。这里降一档为「引用优先 + 置信分层」：
///  - LLM 输出的每条事实必须附带 `src`（从原文一字不改抄出的定位片段）；
///  - `src` 能在原文中对齐（空白归一化后包含）→ 正常置信，provenance 带引用；
///  - 对不齐 → 低置信（provenance.quote = nil），弹药面板显示「AI 不确定，请补全」，
///    **绝不静默采信**；
///  - 抽出的事实一律 `locked = nil`（草稿态）——确认权在用户手里。
///
/// 隐私与计费与全库同纪律：走 `Settings.sendContextToLLM` 同一道门（第 5 个消费点）；
/// 受管密钥按次计量，额度不足时优雅退回离线分段（简历依然进得来，只是要手动整理）。
enum ResumeExtractor {
    struct Result {
        let sheet: FactSheet
        let sections: [ResumeSection]
        let usedLLM: Bool
        /// 低置信条目数（provenance.quote == nil 的经历/动机/概要）。
        let uncertainCount: Int
    }

    /// 离线分段的一节：标题（识别到的话）+ 正文。UI 的 <100ms 即时反馈用它
    /// （「读到 5 个区块：教育 / 项目经历 ×3 / 技能」），无 LLM 路径用它做手动整理底稿。
    struct ResumeSection {
        let title: String?
        let body: String
    }

    typealias Completion = (_ system: String, _ user: String) async throws -> String

    /// LLM leg availability：与实时生成/路由/稿件归一化同一道隐私门，加一把钥匙。
    static var isLLMAvailable: Bool {
        Settings.sendContextToLLM && ProviderRegistry.llmResolution() != LLMResolution.none
    }

    /// 一次简历抽取按 1 分钟额度计（与稿件归一化同口径；最多 6 万字入模）。
    static let chargeSeconds = 60

    // MARK: - Deterministic leg（离线，<100ms）

    /// 简历常见段落标题（zh/ja/en）。命中即成节边界；配合 Markdown 标题与
    /// 「短行 + 无句读」启发式。
    private static let knownHeadings: [String] = [
        // zh
        "基本信息", "个人信息", "求职意向", "教育背景", "教育经历", "学历",
        "工作经历", "实习经历", "项目经历", "项目经验", "专业技能", "技能",
        "自我评价", "个人总结", "获奖", "证书", "校园经历",
        // ja
        "学歴", "職歴", "職務経歴", "自己PR", "スキル", "資格", "志望動機", "受賞",
        // en
        "education", "experience", "work experience", "projects", "skills",
        "summary", "certifications", "awards",
    ]

    static func sectionize(_ doc: ResumeDocument) -> [ResumeSection] {
        var sections: [ResumeSection] = []
        var title: String?
        var body: [String] = []
        func flush() {
            let text = body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if title != nil || !text.isEmpty {
                sections.append(ResumeSection(title: title, body: text))
            }
            title = nil
            body = []
        }
        for rawLine in doc.plainText.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if let heading = headingText(line) {
                flush()
                title = heading
            } else {
                body.append(line)
            }
        }
        flush()
        return sections
    }

    /// 一行是否是段落标题；是则返回去掉记号后的标题文本。
    static func headingText(_ line: String) -> String? {
        var t = line
        // Markdown 标题：# 的层级不重要，剥掉即认。
        if t.hasPrefix("#") {
            t = t.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
            return t.isEmpty ? nil : t
        }
        // 【技能】/ [Skills] 括号包裹的短标题。
        for (open, close) in [("【", "】"), ("[", "]")] where t.hasPrefix(open) && t.hasSuffix(close) {
            let inner = String(t.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
            if !inner.isEmpty, inner.count <= 20 { return inner }
        }
        // 短行 + 无句读 + 命中已知标题词。全靠词表：不然「负责后端开发」这类短行会误判。
        guard t.count <= 20, !t.contains(where: { "。．！？!?，,；;".contains($0) }) else { return nil }
        let bare = t.hasSuffix("：") || t.hasSuffix(":")
            ? String(t.dropLast()).trimmingCharacters(in: .whitespaces) : t
        let lower = bare.lowercased()
        return knownHeadings.contains { lower == $0 || (lower.contains($0) && $0.count >= 2 && !$0.allSatisfy(\.isASCII)) }
            ? bare : nil
    }

    static func deterministic(_ doc: ResumeDocument) -> Result {
        // 离线路径不编造结构化事实：只给分节底稿，确认权与整理权都在用户。
        Result(sheet: .empty, sections: sectionize(doc), usedLLM: false, uncertainCount: 0)
    }

    // MARK: - 简历 vs 面试稿分流（「装填弹药」统一入口）

    /// 简历**专属**标题词（分类用子集）：刻意与面试稿常见话题零交集——
    /// 稿件会用「志望動機/自己PR/自我介绍」当标题，这些绝不能进这张表，
    /// 否则日文稿会被误判成简历。
    static let resumeOnlyHeadings: [String] = [
        "教育背景", "教育经历", "学历", "工作经历", "实习经历", "项目经历", "项目经验",
        "专业技能", "基本信息", "个人信息", "校园经历", "获奖", "证书",
        "学歴", "職歴", "職務経歴", "資格",
        "education", "work experience", "certifications",
    ]

    /// 文档里命中简历专属标题的行数。≥2 即强简历信号。
    static func resumeSignalCount(_ text: String) -> Int {
        var signals = 0
        for raw in text.components(separatedBy: "\n") {
            var t = raw.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("#") { t = t.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces) }
            if t.hasPrefix("【"), t.hasSuffix("】"), t.count >= 3 {
                t = String(t.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
            }
            if t.hasSuffix("：") || t.hasSuffix(":") {
                t = String(t.dropLast()).trimmingCharacters(in: .whitespaces)
            }
            guard !t.isEmpty, t.count <= 20 else { continue }
            let lower = t.lowercased()
            if resumeOnlyHeadings.contains(where: {
                lower == $0 || (lower.contains($0) && !$0.allSatisfy(\.isASCII))
            }) {
                signals += 1
            }
        }
        return signals
    }

    // MARK: - Extraction pipeline

    /// `complete` is injectable for tests; nil wires FastLLM when available.
    static func extract(_ doc: ResumeDocument, complete: Completion? = nil) async -> Result {
        let det = deterministic(doc)
        guard doc.plainText.count < 60_000 else { return det }   // pathological paste — stay offline
        // 受管 LLM 的按次计量（与 ScriptImporter 同一条纪律：绕过计量的路径就是 bug）。
        // 计量失败退回离线分段，简历依然进得来。
        if complete == nil, isLLMAvailable,
           !CreditManager.shared.chargeOneShot(seconds: chargeSeconds) {
            NSLog("[resume] insufficient credit — offline sectionize only")
            return det
        }
        let transport: Completion? = complete ?? (isLLMAvailable
            ? { sys, user in try await FastLLM.complete(system: sys, user: user, maxTokens: 4096) }
            : nil)
        guard let transport,
              let raw = try? await transport(extractSystemPrompt, "简历原文:\n\(doc.plainText)"),
              let (sheet, uncertain) = parseExtraction(raw, doc: doc) else {
            return det
        }
        NSLog("[resume] extraction accepted: %d experiences / %d motivations / %d notes (%d uncertain)",
              sheet.experiences.count, sheet.motivations.count, sheet.notes.count, uncertain)
        return Result(sheet: sheet, sections: det.sections, usedLLM: true, uncertainCount: uncertain)
    }

    // MARK: - LLM extraction（结构化重述 + 引用定位）

    static let extractSystemPrompt = """
    你是简历结构化解析器。从简历原文中抽取结构化事实。只输出 JSON，禁止解释。
    格式: {"profile":{"text":"一句话概括","src":"原文片段"},
          "experiences":[{"role":"角色/职位","org":"组织","period":"时段","actions":["做了什么"],"results":["量化成果"],"skills":["技能"],"src":"原文片段"}],
          "motivations":[{"company":"目标公司","statement":"求职动机","axis":"职业标准","src":"原文片段"}],
          "notes":[{"text":"杂项事实","src":"原文片段"}]}
    规则:
    - 每条的 src 必须是从原文中一字不改抄出的定位片段（20〜60 字），标明这条事实抽取自哪里。
    - 字段内容保留简历原文的语言，不翻译；只做结构化拆分，不润色、不补全原文没有的信息。
    - results 只放有数字或可量化的成果；没有就留空数组。
    - motivations 只在原文明确写了求职意向/志望動機时才输出；company 没写就为空字符串。
    - notes 放不属于经历/动机的关键杂项（期望薪资、到岗时间、语言成绩等），每条一个事实。
    - 没有的字段用空数组。绝不编造原文没有的内容。
    """

    /// 机械校验 + 置信分层。返回 nil = 整体不可用（上层退回离线分段）。
    static func parseExtraction(_ raw: String, doc: ResumeDocument) -> (FactSheet, uncertain: Int)? {
        guard let lo = raw.firstIndex(of: "{"), let hi = raw.lastIndex(of: "}"),
              let data = String(raw[lo...hi]).data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let compactDoc = compact(doc.plainText)
        var uncertain = 0

        /// src → provenance：对齐得上才带引用；对不齐记一笔低置信。
        func provenance(_ item: [String: Any]) -> Provenance {
            let src = ((item["src"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !src.isEmpty, src.count <= 200, compactDoc.contains(compact(src)) {
                return Provenance(source: doc.sourceName, quote: src)
            }
            uncertain += 1
            return Provenance(source: doc.sourceName, quote: nil)
        }
        func strings(_ any: Any?) -> [String] {
            ((any as? [Any]) ?? []).compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        func str(_ any: Any?) -> String {
            ((any as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var sheet = FactSheet.empty
        if let p = obj["profile"] as? [String: Any] {
            let text = str(p["text"])
            if !text.isEmpty, text.count <= 200 {
                _ = provenance(p)   // profile 是概括性改写，引用只用于计数置信，不落 provenance 字段
                sheet.profile = text
            }
        }
        for (i, item) in ((obj["experiences"] as? [[String: Any]]) ?? []).enumerated() {
            let role = str(item["role"]), org = str(item["org"])
            guard !role.isEmpty || !org.isEmpty else { continue }
            sheet.experiences.append(Experience(
                id: "imp-exp-\(i + 1)",
                role: role, org: org, period: str(item["period"]),
                actions: strings(item["actions"]),
                results: strings(item["results"]),
                skills: strings(item["skills"]),
                locked: nil,
                provenance: provenance(item)))
        }
        for (i, item) in ((obj["motivations"] as? [[String: Any]]) ?? []).enumerated() {
            let statement = str(item["statement"])
            guard !statement.isEmpty else { continue }
            let company = str(item["company"])
            let axis = str(item["axis"])
            sheet.motivations.append(Motivation(
                id: "imp-mot-\(i + 1)",
                targetCompany: company.isEmpty ? nil : company,
                statement: statement,
                careerAxis: axis.isEmpty ? nil : axis,
                locked: nil,
                provenance: provenance(item)))
        }
        for item in (obj["notes"] as? [[String: Any]]) ?? [] {
            let text = str(item["text"])
            guard !text.isEmpty, text.count <= 200 else { continue }
            // notes 是 [String]（无 provenance 字段可挂），对不齐的直接丢弃而不是带病收录。
            let src = str(item["src"])
            guard !src.isEmpty, compactDoc.contains(compact(src)) else { continue }
            sheet.notes.append(text)
        }

        // 整体空产出 = 抽取失败（比如模型答非所问），退回离线路径。
        guard sheet.profile != nil || !sheet.experiences.isEmpty
                || !sheet.motivations.isEmpty || !sheet.notes.isEmpty else { return nil }
        return (sheet, uncertain)
    }

    private static func compact(_ s: String) -> String {
        s.components(separatedBy: .whitespacesAndNewlines).joined()
    }
}
