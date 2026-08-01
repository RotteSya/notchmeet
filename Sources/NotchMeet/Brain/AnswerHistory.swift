import Foundation

/// 本场面试里刘海**真正显示过**的回答，按原文完整保留，供临场回看。
///
/// 和 `TurnManager.history` 不是一回事：那份是喂给 LLM 的摘要（每条截 300 字、只留 4 轮），
/// 拿去显示等于给用户一段被砍断的答案——比不给更糟。这里存原文。
///
/// 只活在内存里：面试转录不该在进程之外存活，「删除本地数据」也不该有一个它不知道的文件。
/// 所有方法在主线程调用（同 `ScriptStore` 的约定）。
final class AnswerHistory {
    struct Entry {
        let epoch: Int
        let question: String
        let answer: String
        let intent: String
    }

    /// 旧 → 新。设上限，一场长面试也不会无限增长。
    private(set) var entries: [Entry] = []
    private let maxEntries = 24

    /// nil = 正在显示实时内容；否则是 `entries` 的下标。
    private(set) var cursor: Int?

    private let model: AnswerModel
    /// 进入回看那一刻屏幕上的东西，回到实时时原样还原——回看不能把正在生成的答案吃掉。
    private var liveSnapshot: Snapshot?

    init(model: AnswerModel) { self.model = model }

    var isReviewing: Bool { cursor != nil }
    /// 还有更早的回答可看（菜单据此置灰，不给死按钮）。
    var canStepBack: Bool { targetForStepBack() != nil }

    // MARK: - 记录

    /// 一轮问答定稿。同一轮重复调用（迟到的原稿命中替换了流式答案）就地更新，不堆重复项。
    func record(epoch: Int, question: String, answer: String, intent: String) {
        let text = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !text.isEmpty else { return }
        let entry = Entry(epoch: epoch, question: question, answer: text, intent: intent)
        if let last = entries.last, last.epoch == epoch {
            entries[entries.count - 1] = entry
        } else {
            entries.append(entry)
        }
        if entries.count > maxEntries { entries.removeFirst(entries.count - maxEntries) }
    }

    /// 新一场录音开始：上一场的回答不能串进这一场。
    func reset() {
        abandonReview()
        entries.removeAll()
    }

    // MARK: - 回看

    /// 往回退一条。已经在最早一条时再按 = 回到实时（单键循环，不必再占一个全局热键）。
    func stepBack() {
        guard let target = targetForStepBack() else {
            if cursor != nil { returnToLive() } else { NSLog("[review] no earlier answer to show") }
            return
        }
        if cursor == nil { liveSnapshot = Snapshot(model) }
        apply(index: target)
    }

    /// 往后进一条；越过最新一条 = 回到实时。
    func stepForward() {
        guard let c = cursor else { return }
        let next = c + 1
        if next < entries.count, entries[next].answer != liveSnapshot?.answer {
            apply(index: next)
        } else {
            returnToLive()
        }
    }

    /// 用户主动回到实时：还原进入回看时的那一屏。
    func returnToLive() {
        guard cursor != nil else { return }
        cursor = nil
        model.review = nil
        liveSnapshot?.restore(to: model)
        liveSnapshot = nil
    }

    /// 新一轮问答开始：离开回看但**不还原**——TurnManager 正要写它自己的问题与答案，
    /// 还原会把新回合的字段盖掉。面试里落后于当下比看不到旧答案更糟，所以实时永远优先。
    func abandonReview() {
        guard cursor != nil else { return }
        NSLog("[review] new turn arrived — leaving review")
        cursor = nil
        liveSnapshot = nil
        model.review = nil
    }

    // MARK: - 内部

    private func targetForStepBack() -> Int? {
        guard !entries.isEmpty else { return nil }
        if let c = cursor { return c > 0 ? c - 1 : nil }
        // 进入回看：跳过「此刻已经在屏幕上的那条」——用户要找的是被它替换掉的上一条。
        var i = entries.count - 1
        if entries[i].answer == model.answer { i -= 1 }
        return i >= 0 ? i : nil
    }

    private func apply(index: Int) {
        let e = entries[index]
        cursor = index
        model.answer = e.answer
        model.question = e.question
        model.intentLabel = e.intent
        model.errorDetail = nil
        model.message = .completed
        model.status = .presenting
        model.review = AnswerModel.ReviewBadge(position: index + 1, count: entries.count)
        NSLog("[review] showing answer %d/%d", index + 1, entries.count)
    }

    private struct Snapshot {
        let answer: String
        let question: String
        let intent: String
        let message: RuntimeMessage
        let status: AnswerModel.Status
        let errorDetail: String?

        init(_ m: AnswerModel) {
            answer = m.answer
            question = m.question
            intent = m.intentLabel
            message = m.message
            status = m.status
            errorDetail = m.errorDetail
        }

        func restore(to m: AnswerModel) {
            m.answer = answer
            m.question = question
            m.intentLabel = intent
            m.message = message
            m.status = status
            m.errorDetail = errorDetail
        }
    }
}
