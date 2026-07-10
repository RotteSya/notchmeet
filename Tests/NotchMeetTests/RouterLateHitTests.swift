import XCTest
import os
@testable import notchmeet

/// F4: 路由（缓存/逐字稿）与 live 生成赛跑的提交规则。
/// 旧行为：live 第一句先提交后，晚到的路由命中被无日志丢弃 —— 用户准备好的逐字稿
/// 答案永远不出现。新行为：live 还在流式时，晚到命中升级替换为逐字稿；live 已经
/// 定稿（presenting）则保留现状（只记日志），不在用户朗读中途换稿。
final class RouterLateHitTests: XCTestCase {
    private final class StubRouter: Router, @unchecked Sendable {
        let delayNs: UInt64
        let answer: String?
        init(delayMs: UInt64, answer: String?) {
            self.delayNs = delayMs * 1_000_000
            self.answer = answer
        }
        func route(question: String, candidates: [BankEntry]) async throws -> RouteDecision {
            try await Task.sleep(nanoseconds: delayNs)
            return RouteDecision(intent: "自己紹介", matchedAnswer: answer)
        }
    }

    /// 先吐出第一句（触发 live 提交），然后按需保持「仍在流式」或立即完成。
    private final class StubGenerator: AnswerGenerator, @unchecked Sendable {
        let firstDelayNs: UInt64
        let holdNs: UInt64
        init(firstDelayMs: UInt64 = 0, holdMs: UInt64 = 0) {
            self.firstDelayNs = firstDelayMs * 1_000_000
            self.holdNs = holdMs * 1_000_000
        }
        func generate(_ req: GenRequest, epoch: Int, onDelta: @escaping (String) -> Void) async throws {
            if firstDelayNs > 0 { try await Task.sleep(nanoseconds: firstDelayNs) }
            onDelta("これは生成された最初の文です。")
            if holdNs > 0 { try? await Task.sleep(nanoseconds: holdNs) }  // still streaming…
        }
    }

    private let verbatim = "王雪釵と申します。準備済みの回答です。"

    private func makeStore() -> ScriptStore {
        let dir = NSTemporaryDirectory() + "rl-\(UUID().uuidString)"
        let store = ScriptStore(directory: dir)
        store.add(name: "t", entries: [BankEntry(id: "s1", intent: "自己紹介", question: "自己紹介",
                                                 answer: verbatim, locked: true)])
        return store
    }

    override func setUp() {
        super.setUp()
        setenv("FI_SETTLE_MS", "40", 1)
    }

    @MainActor
    private func runTurn(model: AnswerModel, router: Router, generator: AnswerGenerator,
                         settleFor: TimeInterval) {
        let turn = TurnManager(model: model, generator: generator,
                               router: router, scriptStore: makeStore())
        turn.paused = false
        turn.handleTranscript(Transcript(text: "自己紹介をお願いします。", isFinal: true, confidence: 0.95))
        let exp = expectation(description: "turn settles")
        DispatchQueue.main.asyncAfter(deadline: .now() + settleFor) { exp.fulfill() }
        wait(for: [exp], timeout: settleFor + 2)
        withExtendedLifetime(turn) {}
    }

    /// 回归网：路由先返回 → 逐字稿直接赢（既有行为）。
    @MainActor
    func testRouterHitBeforeLiveCommitShowsVerbatim() {
        let model = AnswerModel()
        runTurn(model: model,
                router: StubRouter(delayMs: 10, answer: verbatim),
                generator: StubGenerator(firstDelayMs: 300, holdMs: 0),
                settleFor: 0.5)
        XCTAssertEqual(model.answer, verbatim)
    }

    /// live 第一句先提交、还在流式 → 晚到的命中必须升级替换成逐字稿。
    @MainActor
    func testLateRouterHitUpgradesWhileLiveStillStreaming() {
        let model = AnswerModel()
        runTurn(model: model,
                router: StubRouter(delayMs: 250, answer: verbatim),
                generator: StubGenerator(firstDelayMs: 0, holdMs: 3000),
                settleFor: 0.7)
        XCTAssertEqual(model.answer, verbatim, "late verbatim hit must replace a still-streaming live answer")
    }

    /// live 已经完整定稿 → 晚到命中不再换稿（用户可能已在朗读）。
    @MainActor
    func testLateRouterHitAfterLiveSettledKeepsLiveAnswer() {
        let model = AnswerModel()
        runTurn(model: model,
                router: StubRouter(delayMs: 250, answer: verbatim),
                generator: StubGenerator(firstDelayMs: 0, holdMs: 0),
                settleFor: 0.7)
        XCTAssertEqual(model.answer, "これは生成された最初の文です。",
                       "a settled answer must not swap mid-read")
    }
}
