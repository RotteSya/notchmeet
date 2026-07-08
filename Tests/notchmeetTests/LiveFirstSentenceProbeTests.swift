import XCTest
@testable import notchmeet

/// 一键式 §4 延迟验收探针（默认跳过——涉及真实网络，不属于常规单测）：
///
///     FI_LIVE_PROBE=1 [TZ=Asia/Shanghai] [DEEPSEEK_API_KEY=…] swift test --filter LiveFirstSentenceProbe
///
/// 走**真实**的 provider 解析（地区 + key）与真实流式生成，测「生成开始 → 首个可念出口的
/// 完整句子」的耗时——这是 3s 预算中唯一的非确定性一段。确定性一段（Apple 端点器 0.7s +
/// settle 余量 ~0.1s ≈ 0.8s，见 UtteranceEndpointerTests / SettleCreditTests）在此之上叠加：
/// 断言 0.8s + 首句耗时 ≤ 3s，即国内路径整体达标。
final class LiveFirstSentenceProbeTests: XCTestCase {
    /// 与 TurnManager.hasSpeakableOpening 同一标准：≥12 字且含句读，或 ≥90 字。
    private func speakable(_ text: String) -> Bool {
        let boundaries = CharacterSet(charactersIn: "。！？!?\n")
        return text.count >= 12 && text.rangeOfCharacter(from: boundaries) != nil
            || text.count >= 90
    }

    func testFirstSpeakableSentenceFitsTheThreeSecondBudget() async throws {
        guard ProcessInfo.processInfo.environment["FI_LIVE_PROBE"] == "1" else {
            throw XCTSkip("live probe disabled — set FI_LIVE_PROBE=1 to run against the real network")
        }
        let res = ProviderRegistry.llmResolution()
        guard res != LLMResolution.none else { throw XCTSkip("no LLM key configured") }
        NSLog("[probe] region inChina=%d resolution=%@",
              Settings.isLikelyInChina() ? 1 : 0, String(describing: res))

        let gen = ProviderRegistry.makeGenerator()
        let req = GenRequest(question: "あなたの強みを教えてください。", context: "", history: "")
        let deterministicLegMs = 800.0   // Apple 端点 0.7s + settle 余量 0.1s（单测锁定）

        let t0 = DispatchTime.now().uptimeNanoseconds
        var buf = ""
        var firstMs: Double?
        try await gen.generate(req, epoch: 0) { delta in
            buf += delta   // deltas arrive sequentially inside generate()'s task
            if firstMs == nil, self.speakable(buf) {
                firstMs = Double(DispatchTime.now().uptimeNanoseconds &- t0) / 1_000_000
            }
        }
        let totalMs = Double(DispatchTime.now().uptimeNanoseconds &- t0) / 1_000_000
        if firstMs == nil, !buf.isEmpty { firstMs = totalMs }   // 短答从未跨过阈值 → 完成即首句

        let first = try XCTUnwrap(firstMs, "provider streamed nothing")
        NSLog("[probe] first_sentence=%dms full_answer=%dms → end-to-end ≈ %dms (budget 3000ms)",
              Int(first), Int(totalMs), Int(deterministicLegMs + first))
        XCTAssertLessThan(deterministicLegMs + first, 3000,
                          "端点+settle (0.8s) + 首句必须落在 3s 内")
    }
}
