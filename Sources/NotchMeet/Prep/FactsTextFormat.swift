import Foundation

/// 简历事实（`FactSheet`）与纯文本之间的确定性双向转换。
///
/// 为什么是文本而不是一堆嵌套表单：`FactSheet` 是「结构里套数组」的形状，做成表单要几百行
/// AppKit，而用户真正要做的事只是把自己的经历、志望、以及几个硬数字（希望年収 / 入社可能
/// 時期 / TOEIC / 研究室）写下来。原稿导入已经用同一套「# 标题 + 正文」约定，用户学一次即可。
///
/// 离线、无 API Key、不联网——与 `ScriptParser` 同一条原则：**永远不让 LLM 有改写事实的通道**。
///
/// 约定（标签接受中日两种写法，回写时统一成日语——事实本身是要送进日语 prompt 的）：
/// ```
/// # プロフィール
/// △△大学大学院で経営学を専攻。
///
/// # 経験: □□株式会社でのインターン
/// 役割: チームリーダー
/// 期間: 2024.07-2024.09
/// 行動: 国籍の異なる5名のチームをまとめた
/// 成果: 来場者の待ち時間を20%短縮
/// スキル: 多国籍チーム運営 / 調整力
///
/// # 志望: JINS
/// 軸: ものづくりと接客の両立
/// 理由: 貴社を志望する理由は……
///
/// # メモ
/// 希望年収: 400万円
/// 入社可能時期: 2026年4月
/// ```
enum FactsTextFormat {

    // MARK: - 解析

    static func parse(_ text: String) -> FactSheet {
        var profile: [String] = []
        var experiences: [Experience] = []
        var motivations: [Motivation] = []
        var notes: [String] = []

        var section: Section = .profile          // 首个标题之前的自由文本当作简介
        var experience: Draft?
        var motivation: MotivationDraft?

        func flush() {
            if let e = experience {
                experiences.append(e.build(index: experiences.count + 1))
                experience = nil
            }
            if let m = motivation {
                motivations.append(m.build(index: motivations.count + 1))
                motivation = nil
            }
        }

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }

            if let heading = heading(of: line) {
                flush()
                section = heading.section
                switch heading.section {
                case .experience: experience = Draft(org: heading.title)
                case .motivation: motivation = MotivationDraft(company: heading.title)
                case .profile, .notes: break
                }
                continue
            }

            let field = labeled(line)
            switch section {
            case .profile:
                profile.append(line)
            case .notes:
                notes.append(stripBullet(line))
            case .experience:
                guard var draft = experience else { break }
                switch field?.key {
                case .role:   draft.role = field!.value
                case .org:    draft.org = field!.value
                case .period: draft.period = field!.value
                case .result: draft.results.append(field!.value)
                case .skill:  draft.skills.append(contentsOf: splitList(field!.value))
                case .action: draft.actions.append(field!.value)
                // 没打标签的行不丢弃——大多数人就是直接写做过什么，当作「行動」收下。
                default:      draft.actions.append(stripBullet(line))
                }
                experience = draft
            case .motivation:
                guard var draft = motivation else { break }
                switch field?.key {
                case .axis:      draft.axis = field!.value
                case .statement: draft.statement.append(field!.value)
                default:         draft.statement.append(stripBullet(line))
                }
                motivation = draft
            }
        }
        flush()

        let profileText = profile.joined(separator: "\n")
        return FactSheet(profile: profileText.isEmpty ? nil : profileText,
                         experiences: experiences,
                         motivations: motivations,
                         notes: notes)
    }

    // MARK: - 回写（用于把已存的事实读回编辑器）

    static func text(for sheet: FactSheet) -> String {
        var blocks: [String] = []
        if let p = sheet.profile, !p.isEmpty {
            blocks.append("# プロフィール\n\(p)")
        }
        for e in sheet.experiences {
            var lines = ["# 経験: \(e.org)"]
            if !e.role.isEmpty { lines.append("役割: \(e.role)") }
            if !e.period.isEmpty { lines.append("期間: \(e.period)") }
            lines += e.actions.map { "行動: \($0)" }
            lines += e.results.map { "成果: \($0)" }
            if !e.skills.isEmpty { lines.append("スキル: \(e.skills.joined(separator: " / "))") }
            blocks.append(lines.joined(separator: "\n"))
        }
        for m in sheet.motivations {
            let company = m.targetCompany?.trimmingCharacters(in: .whitespaces) ?? ""
            var lines = [company.isEmpty ? "# 志望" : "# 志望: \(company)"]
            if let a = m.careerAxis, !a.isEmpty { lines.append("軸: \(a)") }
            if !m.statement.isEmpty { lines.append("理由: \(m.statement)") }
            blocks.append(lines.joined(separator: "\n"))
        }
        if !sheet.notes.isEmpty {
            blocks.append((["# メモ"] + sheet.notes).joined(separator: "\n"))
        }
        return blocks.joined(separator: "\n\n")
    }

    /// 编辑器的实时识别计数（用户保存前要看得见解析结果，和原稿导入同一条原则）。
    static func summary(_ sheet: FactSheet) -> (experiences: Int, motivations: Int, notes: Int, hasProfile: Bool) {
        (sheet.experiences.count, sheet.motivations.count, sheet.notes.count,
         !(sheet.profile ?? "").isEmpty)
    }

    static var isEmptySheetText: (FactSheet) -> Bool {
        { $0.profile == nil && $0.experiences.isEmpty && $0.motivations.isEmpty && $0.notes.isEmpty }
    }

    /// 「示例」按钮插入的模板。数字类问题（希望年収 / 入社可能時期 / 語学スコア）刻意放进
    /// メモ —— 面试官最期待秒答、答含糊最伤的就是这一类。
    static let sample = """
        # プロフィール
        △△大学大学院で経営学を専攻。海外出身、日本で長期的に働きたいと考えています。

        # 経験: □□株式会社でのインターン
        役割: 運営チームリーダー
        期間: 2024.07-2024.09
        行動: 国籍の異なる5名のチームをまとめ、来場者対応の手順を再設計しました
        成果: 待ち時間を約20%短縮
        スキル: 多国籍チーム運営 / 調整力

        # 志望: 〇〇株式会社
        軸: ものづくりと人に向き合う仕事の両立
        理由: 貴社の〇〇という姿勢に共感し、これまでの〇〇の経験を生かせると考えました。

        # メモ
        希望年収: 400万円（応相談）
        入社可能時期: 2026年4月
        TOEIC: 850点
        研究室: 〇〇研究室（テーマ: 〇〇）
        """

    // MARK: - 内部

    private enum Section { case profile, experience, motivation, notes }
    private enum FieldKey { case role, org, period, action, result, skill, axis, statement }

    private struct Draft {
        var org: String
        var role = ""
        var period = ""
        var actions: [String] = []
        var results: [String] = []
        var skills: [String] = []

        func build(index: Int) -> Experience {
            Experience(id: "e\(index)", role: role, org: org, period: period,
                       actions: actions, results: results, skills: skills, locked: true)
        }
    }

    private struct MotivationDraft {
        var company: String
        var axis = ""
        var statement: [String] = []

        func build(index: Int) -> Motivation {
            Motivation(id: "m\(index)",
                       targetCompany: company.isEmpty ? nil : company,
                       statement: statement.joined(separator: "\n"),
                       careerAxis: axis.isEmpty ? nil : axis,
                       locked: true)
        }
    }

    /// `# 経験: タイトル` → (section, title)。非标题行返回 nil。
    private static func heading(of line: String) -> (section: Section, title: String)? {
        guard line.hasPrefix("#") else { return nil }
        let body = line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
        guard !body.isEmpty else { return nil }
        let (keyword, title) = splitLabel(body)
        guard let section = section(for: keyword) else { return nil }
        return (section, title)
    }

    private static func section(for keyword: String) -> Section? {
        let k = normalized(keyword)
        if ["プロフィール", "自己紹介", "简介", "个人简介", "简历", "profile"].contains(k) { return .profile }
        if ["経験", "経歴", "职业经历", "经历", "经验", "experience"].contains(k) { return .experience }
        if ["志望", "志望動機", "志望理由", "志望", "动机", "志望动机", "motivation"].contains(k) { return .motivation }
        if ["メモ", "備考", "備考メモ", "自己分析", "备忘", "笔记", "notes", "note"].contains(k) { return .notes }
        return nil
    }

    private static func labeled(_ line: String) -> (key: FieldKey, value: String)? {
        let (label, value) = splitLabel(line)
        guard !value.isEmpty else { return nil }
        let k = normalized(label)
        switch k {
        case "役割", "役职", "角色", "role":                    return (.role, value)
        case "組織", "会社", "所属", "组织", "公司", "org":       return (.org, value)
        case "期間", "期间", "时间", "period":                   return (.period, value)
        case "行動", "行动", "取り組み", "action":               return (.action, value)
        case "成果", "結果", "结果", "result":                   return (.result, value)
        case "スキル", "技能", "skill", "skills":                return (.skill, value)
        case "軸", "轴", "就活の軸", "axis":                     return (.axis, value)
        case "理由", "本文", "statement":                       return (.statement, value)
        default: return nil
        }
    }

    /// `ラベル: 値` を分割（全角コロンも受ける）。ラベルが無ければ (line, "")。
    private static func splitLabel(_ s: String) -> (String, String) {
        guard let i = s.firstIndex(where: { $0 == ":" || $0 == "：" }) else { return (s, "") }
        let label = String(s[s.startIndex..<i]).trimmingCharacters(in: .whitespaces)
        let value = String(s[s.index(after: i)...]).trimmingCharacters(in: .whitespaces)
        return (label, value)
    }

    private static func normalized(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func stripBullet(_ s: String) -> String {
        var t = s
        for bullet in ["- ", "・", "* ", "• ", "-", "*"] where t.hasPrefix(bullet) {
            t = String(t.dropFirst(bullet.count))
            break
        }
        return t.trimmingCharacters(in: .whitespaces)
    }

    private static func splitList(_ s: String) -> [String] {
        s.components(separatedBy: CharacterSet(charactersIn: "/／、,，"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
