import Foundation

/// 面试复盘记录（审计 #21）。
///
/// 此前每一场面试的问答只活在内存里（`TurnManager.history` 保 4 轮、`AnswerHistory`
/// 保本场），进程一结束全部蒸发。于是「哪几问没命中我准备的内容、下次该往稿子里补
/// 什么」这个唯一能让人越面越准的信号，用户永远拿不到——打十场也不会变好。
///
/// 存的是面试转录，是这个 app 里最敏感的数据。因此：仅本机、0600、进「删除本地数据」
/// 的清单、在隐私页明说、可关（`Settings.keepSessionHistory`）。
struct InterviewSession: Codable, Identifiable {
    let id: String
    let startedAt: Date
    var endedAt: Date?
    /// 本场选用的稿件名（没选就是 nil）——复盘时要知道当时拿的是哪一份。
    var scriptName: String?
    var turns: [Turn]

    struct Turn: Codable {
        let question: String
        let answer: String
        let source: AnswerSource
        let at: Date
    }

    var hitCount: Int { turns.filter(\.source.isPrepared).count }
    /// 未命中的问题＝改稿清单，复盘页的主角。
    var misses: [Turn] { turns.filter { !$0.source.isPrepared } }
}

/// 这一轮的答案从哪来。区分「我准备的」与「现场编的」是复盘的全部意义所在。
enum AnswerSource: String, Codable {
    /// 命中用户手写的面试原稿——逐字读出的就是准备好的内容。
    case script
    /// 命中 AI 预生成的答案库——是准备好的，但内容通用，未必贴合本人。
    case bank
    /// 本机确定性事实即答（希望年収/入社時期…）——也是「准备到了」。
    case fact
    /// 现场生成。
    case live

    /// 「算不算准备到了」。bank 计入命中但复盘页会单独标出来：它绕过了原稿，
    /// 内容是模板化的，命中率高不代表回答有竞争力。
    var isPrepared: Bool { self != .live }
}

/// 落盘与读取。所有方法在主线程调用（同 ScriptStore 的约定）。
final class SessionStore {
    /// 只保留最近这么多场：复盘看的是最近几家，不是流水账；也限制转录在磁盘上的量。
    private let maxSessions = 20
    private let path: String
    private(set) var sessions: [InterviewSession] = []
    private var current: InterviewSession?

    init(directory: String = KnowledgePaths.dir) {
        self.path = directory + "/sessions.json"
        reload()
    }

    var hasHistory: Bool { !sessions.isEmpty }

    // MARK: - 录制

    /// 开始新一场。关掉开关时什么都不记。
    func begin(scriptName: String?) {
        guard Settings.keepSessionHistory else { current = nil; return }
        current = InterviewSession(id: UUID().uuidString, startedAt: Date(),
                                   endedAt: nil, scriptName: scriptName, turns: [])
    }

    func record(question: String, answer: String, source: AnswerSource, at: Date = Date()) {
        guard Settings.keepSessionHistory, current != nil else { return }
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let a = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !a.isEmpty else { return }
        current?.turns.append(.init(question: q, answer: a, source: source, at: at))
    }

    /// 结束本场并落盘。一问都没有的场次不留记录（点开又关掉不该产出一条空复盘）。
    @discardableResult
    func end() -> Bool {
        guard var session = current else { return true }
        current = nil
        guard !session.turns.isEmpty else { return true }
        session.endedAt = Date()
        sessions.insert(session, at: 0)               // 新的在前
        if sessions.count > maxSessions { sessions.removeLast(sessions.count - maxSessions) }
        return save()
    }

    // MARK: - 持久化

    func reload() {
        guard let data = FileManager.default.contents(atPath: path) else { sessions = []; return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601   // 必须与 save() 的编码策略同源
        guard let decoded = try? decoder.decode([InterviewSession].self, from: data) else {
            // 解不开就当没有：复盘是回顾用的，绝不能因为它挡住主流程，也不值得像
            // scripts.json 那样做隔离——那份是用户手写、不可再生的。
            NSLog("[session] log unreadable (%d bytes) — starting fresh", data.count)
            sessions = []
            return
        }
        sessions = decoded
    }

    @discardableResult
    func save() -> Bool {
        do {
            let dir = (path as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(sessions)
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            // 面试转录：仅本用户可读（未沙箱，默认 0644 同机可读）。同 scripts.json。
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
            return true
        } catch {
            NSLog("[session] SAVE FAILED (%@): %@", path, String(describing: error))
            return false
        }
    }

    /// 关掉开关或用户主动清空时用。
    func clear() {
        sessions = []
        current = nil
        try? FileManager.default.removeItem(atPath: path)
    }
}
