import Foundation

/// 连续慢终稿探测（审计 R1）——纯逻辑，供 AppController 决定是否热切换端侧引擎。
///
/// 针对的形态：Deepgram 连接**活着**、看门狗与重连都不触发，但终稿要 6–14s 才到
/// （实机在晚高峰验证过，是 3s SLA 的头号杀手）。DeepgramSttClient 里的
/// serverSilenceTimeoutNs 管「彻底没有服务端帧」的半开连接；这里管「有帧但慢」。
///
/// 输入是 LatencyMonitor 拆分出的 STT 交付耗时（最后一个音素 → 最后终稿到达，
/// 不含我们自己的 settle 等待，所以不会把「窗口调大了」误判成「网络慢了」）。
/// 判据：连续 `consecutiveNeeded` 轮超过 `thresholdMs` 才建议降级——单轮尖峰
/// （一次重连补发、一句超长发言）不该换引擎，连续两轮慢就是系统性拥塞。
struct SttHealthTracker {
    /// 默认 3000ms：Deepgram 正常交付（endpointing 300ms + 网络）在 1.5s 内，
    /// 3s 是产品 SLA 的整条预算——STT 一家吃满预算，这一轮已经注定迟到。
    /// FI_STT_SLOW_MS（毫秒）可覆盖，便于 QA 用小阈值触发切换。
    static let defaultThresholdMs: Double = {
        if let s = ProcessInfo.processInfo.environment["FI_STT_SLOW_MS"], let v = Double(s), v > 0 {
            return v
        }
        return 3000
    }()

    let thresholdMs: Double
    let consecutiveNeeded: Int
    private var slowStreak = 0

    init(thresholdMs: Double = SttHealthTracker.defaultThresholdMs, consecutiveNeeded: Int = 2) {
        self.thresholdMs = thresholdMs
        self.consecutiveNeeded = consecutiveNeeded
    }

    /// 记录一轮交付耗时。返回 true = 连续第 N 轮超阈值，建议现在降级
    /// （防重入由调用方负责——降级本身是一次性动作）。
    mutating func note(deliveryMs: Double) -> Bool {
        if deliveryMs > thresholdMs { slowStreak += 1 } else { slowStreak = 0 }
        return slowStreak >= consecutiveNeeded
    }

    /// 新会话 / 已切换引擎后清零。
    mutating func reset() { slowStreak = 0 }
}
