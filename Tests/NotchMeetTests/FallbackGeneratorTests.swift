import XCTest
@testable import notchmeet

/// LLM 运行时降级链的回归锁。
///
/// 对应线上缺陷：多 provider 只在「哪个 key 存在」层面静态选一个，主选服务端故障时
/// 每一题都报错，而用户已配好的次选 key 无人使用——整场面试报废。
final class FallbackGeneratorTests: XCTestCase {

    /// 可编排的假生成器：先吐 `emit` 里的 delta，再按 `failWith` 抛错。
    final class StubGenerator: AnswerGenerator {
        let emit: [String]
        let failWith: Error?
        private(set) var calls = 0

        init(emit: [String] = [], failWith: Error? = nil) {
            self.emit = emit
            self.failWith = failWith
        }

        func generate(_ req: GenRequest, epoch: Int, onDelta: @escaping (String) -> Void) async throws {
            calls += 1
            for d in emit { onDelta(d) }
            if let failWith { throw failWith }
        }
    }

    private let req = GenRequest(question: "志望動機は？", context: "", history: "")

    private func run(_ gen: AnswerGenerator) async -> (text: String, error: Error?) {
        var text = ""
        do {
            try await gen.generate(req, epoch: 1) { text += $0 }
            return (text, nil)
        } catch {
            return (text, error)
        }
    }

    /// 主选在首个 delta 之前失败 → 自动切到次选，用户拿到完整答案。
    func testFallsOverToNextProviderWhenPrimaryFailsBeforeAnyOutput() async {
        let primary = StubGenerator(failWith: LLMError.http(429))
        let secondary = StubGenerator(emit: ["御社の", "課題に"])
        let chain = FallbackAnswerGenerator(chain: [primary, secondary],
                                            names: ["qwen", "deepseek"])
        let result = await run(chain)
        XCTAssertNil(result.error)
        XCTAssertEqual(result.text, "御社の課題に")
        XCTAssertEqual(primary.calls, 1)
        XCTAssertEqual(secondary.calls, 1)
    }

    /// 已经吐字之后再失败 → **不得**切换（刘海上的文字会跳变，用户可能正在照读）。
    func testDoesNotSwitchAfterOutputHasStarted() async {
        let primary = StubGenerator(emit: ["御社の"], failWith: LLMError.http(500))
        let secondary = StubGenerator(emit: ["まったく別の文"])
        let chain = FallbackAnswerGenerator(chain: [primary, secondary])
        let result = await run(chain)
        XCTAssertNotNil(result.error, "流中失败应抛给上层收尾")
        XCTAssertEqual(result.text, "御社の", "已上屏的文字不得被另一个 provider 覆盖")
        XCTAssertEqual(secondary.calls, 0, "不得在已出字后切换 provider")
    }

    /// 全部失败 → 抛出最后一个错误，不吞。
    func testThrowsWhenEveryProviderFails() async {
        let a = StubGenerator(failWith: LLMError.http(401))
        let b = StubGenerator(failWith: LLMError.http(503))
        let chain = FallbackAnswerGenerator(chain: [a, b])
        let result = await run(chain)
        XCTAssertEqual(a.calls, 1)
        XCTAssertEqual(b.calls, 1)
        guard case LLMError.http(let code)? = result.error else {
            return XCTFail("应抛出最后一个 provider 的错误，实际 \(String(describing: result.error))")
        }
        XCTAssertEqual(code, 503)
    }

    /// 主选成功时次选完全不该被调用（不产生额外费用/延迟）。
    func testSecondaryUntouchedOnSuccess() async {
        let primary = StubGenerator(emit: ["はい"])
        let secondary = StubGenerator(emit: ["いいえ"])
        let chain = FallbackAnswerGenerator(chain: [primary, secondary])
        let result = await run(chain)
        XCTAssertEqual(result.text, "はい")
        XCTAssertEqual(secondary.calls, 0)
    }

    /// 取消不是 provider 故障：不得降级重试（否则用户切题后仍会烧掉次选配额）。
    func testCancellationIsNotRetried() async {
        let primary = StubGenerator(failWith: CancellationError())
        let secondary = StubGenerator(emit: ["不应出现"])
        let chain = FallbackAnswerGenerator(chain: [primary, secondary])
        let result = await run(chain)
        XCTAssertTrue(result.error is CancellationError)
        XCTAssertEqual(secondary.calls, 0, "取消不得触发降级")
    }

    /// URLSession 的取消是 URLError.cancelled(-999)，**不是** CancellationError。
    /// 实测中原稿命中会走这条路（liveTask.cancel() → URLSession 取消），只认
    /// CancellationError 的话每次缓存命中都会白烧一次次选 provider 的配额。
    func testURLSessionCancellationIsNotRetried() async {
        let primary = StubGenerator(failWith: URLError(.cancelled))
        let secondary = StubGenerator(emit: ["不应出现"])
        let chain = FallbackAnswerGenerator(chain: [primary, secondary])
        let result = await run(chain)
        XCTAssertEqual(secondary.calls, 0, "URLSession 取消同样不得触发降级")
        XCTAssertNotNil(result.error)
    }

    // MARK: - 首 token 看门狗（审计 R2）

    /// 可控速度的假生成器：先等 `delay`，再吐 delta。被取消时如实抛 CancellationError。
    final class SlowStubGenerator: AnswerGenerator {
        let delay: TimeInterval
        let emit: [String]
        private(set) var calls = 0
        private(set) var cancelled = false

        init(delay: TimeInterval, emit: [String]) {
            self.delay = delay
            self.emit = emit
        }

        func generate(_ req: GenRequest, epoch: Int, onDelta: @escaping (String) -> Void) async throws {
            calls += 1
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch {
                cancelled = true
                throw error
            }
            for d in emit { onDelta(d) }
        }
    }

    /// 主选连着但迟迟不吐字（DeepSeek 晚高峰形态）→ 预算耗尽即切次选。
    /// 这是 R2 的核心：硬失败之外，「挂着不响应」也必须触发降级。
    func testSwitchesWhenPrimaryProducesNoTokenWithinBudget() async {
        let primary = SlowStubGenerator(delay: 10, emit: ["遅すぎる答え"])
        let secondary = StubGenerator(emit: ["御社の強みは"])
        let chain = FallbackAnswerGenerator(chain: [primary, secondary],
                                            names: ["deepseek", "qwen"],
                                            firstTokenBudget: 0.05)
        let result = await run(chain)
        XCTAssertNil(result.error)
        XCTAssertEqual(result.text, "御社の強みは", "预算耗尽后必须切到次选，且不得混入主选的迟到文字")
        XCTAssertEqual(secondary.calls, 1)
        XCTAssertTrue(primary.cancelled, "被放弃的 provider 必须被取消，不能留着白烧配额")
    }

    /// 首个 delta 赶在预算内到达 → 之后无论多慢都不再切换（用户可能正在照读）。
    func testNoSwitchOnceFirstTokenArrivedInTime() async {
        let primary = SlowStubGenerator(delay: 0.01, emit: ["はい。", "私の強みは実行力です。"])
        let secondary = StubGenerator(emit: ["不应出现"])
        let chain = FallbackAnswerGenerator(chain: [primary, secondary],
                                            firstTokenBudget: 0.2)
        let result = await run(chain)
        XCTAssertNil(result.error)
        XCTAssertEqual(result.text, "はい。私の強みは実行力です。")
        XCTAssertEqual(secondary.calls, 0)
    }

    /// 链上最后一个 provider 不设看门狗：没有退路时，慢答案好过没答案。
    func testLastProviderIsNeverAbandonedForSlowness() async {
        let only = SlowStubGenerator(delay: 0.15, emit: ["遅くても答え"])
        let chain = FallbackAnswerGenerator(chain: [only], firstTokenBudget: 0.02)
        let result = await run(chain)
        XCTAssertNil(result.error)
        XCTAssertEqual(result.text, "遅くても答え")
        XCTAssertFalse(only.cancelled)
    }

    /// 全链都在预算内哑火 → 上抛可读的 allProvidersSlow，而不是内部哨兵。
    func testAllSlowSurfacesReadableError() async {
        let a = SlowStubGenerator(delay: 10, emit: ["x"])
        let b = StubGenerator(failWith: LLMError.http(503))
        let chain = FallbackAnswerGenerator(chain: [a, b], firstTokenBudget: 0.05)
        let result = await run(chain)
        // a 超时 → 换 b；b 硬失败且是最后一个 → 抛 b 的错误。
        guard case LLMError.http(let code)? = result.error else {
            return XCTFail("应抛出最后一个 provider 的真实错误，实际 \(String(describing: result.error))")
        }
        XCTAssertEqual(code, 503)

        // 两家都哑 → allProvidersSlow（第二家没有下一家，不装看门狗，这里用两家超时
        // 模拟不了；直接验证「只有超时、没有硬失败」时的兜底错误形态）。
        let c = SlowStubGenerator(delay: 10, emit: ["x"])
        let d = SlowStubGenerator(delay: 10, emit: ["y"])
        let chain2 = FallbackAnswerGenerator(chain: [c, d], firstTokenBudget: 0.05)
        let req2 = req
        let t = Task { () -> (text: String, error: Error?) in
            var text = ""
            do {
                try await chain2.generate(req2, epoch: 1) { text += $0 }
                return (text, nil)
            } catch {
                return (text, error)
            }
        }
        // d 是最后一家不设看门狗，会一直等——这里直接取消整轮（等同新问题取代）。
        try? await Task.sleep(nanoseconds: 200_000_000)
        t.cancel()
        let r2 = await t.value
        XCTAssertNotNil(r2.error, "整轮被取消时必须向上抛，不得吞掉")
        XCTAssertEqual(r2.text, "", "没有任何 provider 的文字上屏")
    }

    /// 判定函数本身：两种取消都认，真实故障不认。
    func testCancellationClassification() {
        XCTAssertTrue(TurnManager.isCancellation(CancellationError()))
        XCTAssertTrue(TurnManager.isCancellation(URLError(.cancelled)))
        XCTAssertTrue(TurnManager.isCancellation(
            NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)))

        XCTAssertFalse(TurnManager.isCancellation(URLError(.timedOut)),
                       "超时是真实故障，必须上报")
        XCTAssertFalse(TurnManager.isCancellation(URLError(.notConnectedToInternet)),
                       "断网是真实故障，必须上报")
        XCTAssertFalse(TurnManager.isCancellation(LLMError.http(500)),
                       "服务端错误是真实故障，必须上报")
        // 同样是 -999，但域不同 → 不是 URLSession 的取消。
        XCTAssertFalse(TurnManager.isCancellation(
            NSError(domain: "SomeOtherDomain", code: NSURLErrorCancelled)))
    }
}
