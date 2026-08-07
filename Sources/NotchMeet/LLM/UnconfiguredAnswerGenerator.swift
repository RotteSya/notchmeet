import Foundation

/// 无任何可用 LLM Key 时，**真实录音会话**用的生成器：立即抛 missingKey，让刘海
/// 显示可行动的错误（「没有可用的 API 密钥，请在设置里配置」）。
///
/// 绝不能退回 MockAnswerGenerator（审计 R6）：它吐出的那段流利的通用模板在刘海上
/// 与真答案毫无区别，候选人会当场照着念一段与自己经历毫无关系的话——比没有答案
/// 危险得多。而 `.auto` 的国内路径恰好容易撞上这一幕：STT 走 Apple 端侧不需要 Key，
/// 管线照常 arm，用户可能直到面试中才发现 LLM 没配。Mock 只允许出现在显式的
/// demo / QA 管线（AppConfig.pipeline == .mock）。
///
/// 本机确定性来源不受影响：facts 即答与（若可用的）原稿命中仍照常工作。
final class UnconfiguredAnswerGenerator: AnswerGenerator {
    func generate(_ req: GenRequest, epoch: Int,
                  onDelta: @escaping (String) -> Void) async throws {
        throw LLMError.missingKey
    }
}
