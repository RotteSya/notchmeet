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
}
