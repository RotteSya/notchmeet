import Combine

/// Observable state the notch renders. Mutated on the main thread by the pipeline.
/// `ObservableObject` / `@Published` are Combine types — the notch is pure AppKit and observes
/// this via `objectWillChange`, no SwiftUI involved.
final class AnswerModel: ObservableObject {
    /// `ready` = armed but NOT capturing (nothing leaves the machine). `listening` and the
    /// AI-working states (`thinking`/`streaming`/`presenting`) only occur while recording.
    enum Status: Equatable { case ready, listening, thinking, streaming, presenting, error }

    @Published var expanded = false
    @Published var status: Status = .ready
    @Published var message: RuntimeMessage = .ready
    /// True only while the audio tap is live and audio is being uploaded. Drives the
    /// unmistakable "REC" treatment (red outline) independent of the activity `status`.
    @Published var recording = false
    @Published var answer = ""          // verbatim user script or streamed spoken answer
    @Published var errorDetail: String?
    @Published var intentLabel = ""     // matched/predicted intent — glance-check against mis-match
    @Published var question = ""        // interviewer's question as recognized by STT — glance-check for mis-hearing
    /// 剩余额度秒数；nil = 本场不计量（BYO/本地）→ 刘海不显示额度胶囊。
    /// 只在计量会话进行中由 AppController 持续写入（每秒随扣费刷新）。
    @Published var creditSeconds: Int?
    /// 非 nil = 此刻显示的是**过去**的某条回答（用户按 ⌘⇧B 回看），由 `AnswerHistory` 写入。
    /// 刘海据此换上醒目的回看标识：旧答案绝不能被读成当前该说的话。
    @Published var review: ReviewBadge?
    /// 需要用户做一次选择时的刘海内提示；nil = 无提示。
    @Published var prompt: NotchPrompt?

    /// 第 `position` 条 / 共 `count` 条（position 为 1 起的显示序号）。
    struct ReviewBadge: Equatable {
        let position: Int
        let count: Int
    }
}

/// 需要用户做一次选择的提示，长在刘海本体里——**不弹模态**。
///
/// NSAlert 的采集暴露已由 `ScreenShareGuard` 堵上，但它仍会抢走面试 App 的焦点并阻塞
/// run loop，这在面试进行中治不了。文案沿用既有的 `message` 通道，这里只描述「有哪些下一步」。
enum NotchPrompt: Equatable {
    /// 额度用完（会话被停止，或余额为 0 无法开始）。
    case credit

    var actions: [NotchPromptAction] {
        switch self {
        case .credit: return [.topUp, .enterCode, .dismiss]
        }
    }

    /// 视觉上被强调的那一个；其余保持安静的次级样式。
    var primaryAction: NotchPromptAction {
        switch self {
        case .credit: return .topUp
        }
    }
}

enum NotchPromptAction: Equatable {
    case topUp      // 打开购买页
    case enterCode  // 设置 → 额度与充值
    case dismiss    // 稍后（只收起提示，不做别的）
}

/// Single display contract for the notch. Non-empty answers are returned byte-for-byte:
/// user scripts are never parsed as Markdown, trimmed, split, numbered, or rewritten.
enum NotchPresentation {
    static func text(answer: String,
                     message: RuntimeMessage,
                     errorDetail: String?,
                     strings: AppStrings) -> String {
        if !answer.isEmpty { return answer }
        if message == .generationError, let errorDetail {
            return strings.generationError(errorDetail)
        }
        if message == .sttError, let errorDetail { return errorDetail }  // SttError.localizedDescription is a full localized sentence
        return strings.runtimeMessage(message)
    }
}
