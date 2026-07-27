import Foundation

/// 按顺序尝试多个 provider，直到有一个**开始产出内容**为止。
///
/// 旧实现只按「哪个 key 存在」静态选出一个 provider，失败即 failTurn。用户同时配了
/// Qwen 和 DeepSeek 时，Qwen 服务端故障或限流会让每一题都显示「回答生成失败」，
/// 而 DeepSeek 的 key 就躺在钥匙串里没人用——整场面试报废。
///
/// 关键约束：一旦已经吐出过 delta 就**不能**再换 provider，否则刘海上的文字会跳变
/// （用户可能正照着念）。此时把错误抛给 TurnManager 收尾。只有「一个字都还没产出」
/// 的失败才降级——那正是鉴权失败/限流/连接失败的典型形态。
final class FallbackAnswerGenerator: AnswerGenerator {
    private let chain: [AnswerGenerator]
    private let names: [String]

    init(chain: [AnswerGenerator], names: [String] = []) {
        precondition(!chain.isEmpty, "FallbackAnswerGenerator requires at least one provider")
        self.chain = chain
        self.names = names
    }

    private func name(_ i: Int) -> String { i < names.count ? names[i] : "provider#\(i)" }

    func generate(_ req: GenRequest, epoch: Int,
                  onDelta: @escaping (String) -> Void) async throws {
        var lastError: Error = LLMError.missingKey
        for (index, provider) in chain.enumerated() {
            var produced = false
            do {
                try await provider.generate(req, epoch: epoch) { delta in
                    produced = true
                    onDelta(delta)
                }
                return
            } catch {
                // 用户切题/新一轮取消：不是 provider 的错，不要降级重试。
                if error is CancellationError || Task.isCancelled { throw error }
                lastError = error
                if produced {
                    NSLog("[llm] %@ failed mid-stream — not switching (text already on screen)",
                          name(index))
                    throw error
                }
                NSLog("[llm] %@ failed before first delta (%@) — trying next",
                      name(index), String(describing: error))
            }
        }
        throw lastError
    }
}
