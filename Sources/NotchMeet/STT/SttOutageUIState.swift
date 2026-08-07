import Foundation

/// 转写断连/重连期间刘海该显示什么——纯状态机，供 AppController 使用（审计 R4/R5）。
///
/// 契约：
/// - 断连只在「常态 → 断连」的边沿拍快照；重连失败导致的反复 disconnected 不覆盖
///   （否则快照会变成 .sttReconnecting 自己）。
/// - 重连成功**只还原快照，绝不清空**：断连恰好发生在展示答案时（网络抖动最常见的
///   时机就是通话中），旧实现的 enterListening() 会把用户正照着念的答案凭空抹掉。
/// - 断连期间回合已推进（LLM 流仍在跑，message 被盖成 .suggesting/.completed）
///   → 重连时什么都不动，正在发生的事永远比「恢复旧状态」优先。
struct SttOutageUIState {
    private var snapshot: (message: RuntimeMessage, status: AnswerModel.Status)?

    /// 连接断开。返回 true = 这是新一轮断连的边沿（调用方应把 message 切到 .sttReconnecting）。
    mutating func noteDisconnected(currentMessage: RuntimeMessage,
                                   currentStatus: AnswerModel.Status) {
        guard currentMessage != .sttReconnecting else { return }
        snapshot = (currentMessage, currentStatus)
    }

    /// 连接恢复。返回该还原成的状态；nil = 不要碰 UI（重连提示已被后续回合盖掉）。
    /// 理论上不可能出现「显示着重连提示却没有快照」——真出现就退到聆听态兜底。
    mutating func noteReconnected(currentMessage: RuntimeMessage)
        -> (message: RuntimeMessage, status: AnswerModel.Status)? {
        defer { snapshot = nil }
        guard currentMessage == .sttReconnecting else { return nil }
        return snapshot ?? (.listening, .listening)
    }
}
