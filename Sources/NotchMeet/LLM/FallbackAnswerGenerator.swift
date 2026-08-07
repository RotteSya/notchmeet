import Foundation
import os

/// 按顺序尝试多个 provider，直到有一个**开始产出内容**为止。
///
/// 旧实现只按「哪个 key 存在」静态选出一个 provider，失败即 failTurn。用户同时配了
/// Qwen 和 DeepSeek 时，Qwen 服务端故障或限流会让每一题都显示「回答生成失败」，
/// 而 DeepSeek 的 key 就躺在钥匙串里没人用——整场面试报废。
///
/// 两种情况会切换到下一个 provider（都以「一个字都还没产出」为前提）：
/// 1. **硬失败**：鉴权失败 / 限流 / 连接失败，请求直接抛错。
/// 2. **首 token 超时**：请求挂着不吐字（DeepSeek 官方 API 晚高峰首 token 实测常态
///    7–8s，而产品的 SLA 是 3s 内出首句）。`LLMHTTP.timeout=15` 是**空闲**超时，
///    每来一个字节就重置，对「连上了但迟迟不出字」完全不设防——这正是审计 R2 的洞。
///    预算内没等到首 token 就取消当前 provider 换下一个；链上**最后一个**不设超时：
///    没有退路时，慢答案好过没答案。
///
/// 关键约束：一旦已经吐出过 delta 就**不能**再换 provider，否则刘海上的文字会跳变
/// （用户可能正照着念）。此时把错误抛给 TurnManager 收尾。切换与首个 delta 的竞争
/// 用一次原子认领裁决：看门狗先到 → 该 provider 之后的迟到 delta 全部丢弃，绝不会
/// 出现两个 provider 的文字拼在同一屏上。
final class FallbackAnswerGenerator: AnswerGenerator {
    private let chain: [AnswerGenerator]
    private let names: [String]
    private let firstTokenBudget: TimeInterval

    /// 首 token 预算（秒）。默认 3s——SLA 就是 3s 内出首句，预算耗尽时这一问已经
    /// 迟了，立刻换下一家是唯一止损。FI_FIRST_TOKEN_MS（毫秒）可覆盖；0 = 关闭。
    static let defaultFirstTokenBudget: TimeInterval = {
        if let s = ProcessInfo.processInfo.environment["FI_FIRST_TOKEN_MS"], let v = Double(s), v >= 0 {
            return v / 1000
        }
        return 3.0
    }()

    /// 内部哨兵：首 token 超时。只在还有下一个 provider 可换时抛出，永远不会
    /// 泄漏给调用方（要么换下一家，要么最后一家根本不装看门狗）。
    struct FirstTokenTimeout: Error {}

    /// 当前 provider 的认领状态：首个 delta 与看门狗超时之间的竞争必须原子裁决，
    /// 否则「刚吐出第一个字的瞬间被切换」会把两家 provider 的文字拼在同一屏上。
    private enum Claim { case none, streaming, abandoned }

    init(chain: [AnswerGenerator], names: [String] = [],
         firstTokenBudget: TimeInterval = FallbackAnswerGenerator.defaultFirstTokenBudget) {
        precondition(!chain.isEmpty, "FallbackAnswerGenerator requires at least one provider")
        self.chain = chain
        self.names = names
        self.firstTokenBudget = firstTokenBudget
    }

    private func name(_ i: Int) -> String { i < names.count ? names[i] : "provider#\(i)" }

    func generate(_ req: GenRequest, epoch: Int,
                  onDelta: @escaping (String) -> Void) async throws {
        var lastError: Error = LLMError.missingKey
        for (index, provider) in chain.enumerated() {
            let hasNext = index + 1 < chain.count
            let claim = OSAllocatedUnfairLock(initialState: Claim.none)
            do {
                try await withThrowingTaskGroup(of: Bool.self) { group in
                    group.addTask {
                        try await provider.generate(req, epoch: epoch) { delta in
                            // 认领：看门狗已放弃的 provider，迟到的 delta 一律丢弃。
                            let deliver = claim.withLock { s -> Bool in
                                if s == .none { s = .streaming }
                                return s == .streaming
                            }
                            if deliver { onDelta(delta) }
                        }
                        return true    // provider 正常收尾
                    }
                    if hasNext, firstTokenBudget > 0 {
                        group.addTask { [budget = firstTokenBudget] in
                            try await Task.sleep(nanoseconds: UInt64(budget * 1_000_000_000))
                            let timedOut = claim.withLock { s -> Bool in
                                if s == .none { s = .abandoned; return true }
                                return false
                            }
                            if timedOut { throw FirstTokenTimeout() }
                            return false   // 已在流式输出，看门狗安静退场
                        }
                    }
                    // 等 provider 本体结束（true）。看门狗先安静结束（false）时继续等。
                    while let providerDone = try await group.next() {
                        if providerDone { group.cancelAll(); return }
                    }
                }
                return
            } catch is FirstTokenTimeout {
                lastError = LLMError.allProvidersSlow   // 只有全链皆哑时才会真的抛给上层
                NSLog("[llm] %@ produced no token within %.1fs — trying next",
                      name(index), firstTokenBudget)
                continue
            } catch {
                // 取消（用户切题 / 缓存赢得竞速 / 新一轮取代）不是 provider 的错，
                // 不要降级重试——否则每次原稿命中都会白烧一次次选 provider 的配额。
                // URLSession 的取消是 URLError.cancelled(-999)，不是 CancellationError。
                if TurnManager.isCancellation(error) || Task.isCancelled { throw error }
                lastError = error
                if claim.withLock({ $0 == .streaming }) {
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
