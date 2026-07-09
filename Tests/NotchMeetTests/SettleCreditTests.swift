import XCTest
import os
@testable import notchmeet

/// Locks in the banked-silence credit: the settle window is silence measured from the
/// interviewer's LAST PHONEME, so the silence the STT engine already consumed before its
/// final arrived (Apple 端点器 ~0.7s、Deepgram endpointing 0.3s) must be deducted — not
/// waited a second time. Windows here are scaled (600ms) for determinism.
final class SettleCreditTests: XCTestCase {
    private final class RecordingGenerator: AnswerGenerator, @unchecked Sendable {
        private let onGenerate: @Sendable () -> Void
        init(onGenerate: @escaping @Sendable () -> Void) { self.onGenerate = onGenerate }
        func generate(_ req: GenRequest, epoch: Int, onDelta: @escaping (String) -> Void) async throws {
            onDelta("はい、私の強みは実行力です。")
            onGenerate()
        }
    }

    private func final(_ text: String) -> Transcript { Transcript(text: text, isFinal: true, confidence: 0.95) }

    @MainActor
    func testBankedSilenceShortensTheSettleWait() {
        setenv("FI_SETTLE_MS", "600", 1)
        let exp = expectation(description: "turn starts early")
        let gen = RecordingGenerator { exp.fulfill() }
        let turn = TurnManager(model: AnswerModel(), generator: gen)
        turn.paused = false
        // 音频路径报告最后有声帧在 500ms 前 —— 端点器已消化了这段静音。
        turn.latency.voicedClock = { DispatchTime.now().uptimeNanoseconds &- 500_000_000 }

        turn.handleTranscript(final("あなたの強みを教えてください。"))

        // 600−500=100ms 后应已提交；旧行为（从 final 到达重新计满 600ms）会超时。
        wait(for: [exp], timeout: 0.4)
    }

    @MainActor
    func testWithoutVoicedClockTheFullWindowStillApplies() {
        setenv("FI_SETTLE_MS", "600", 1)
        let idle = expectation(description: "no early commit")
        idle.isInverted = true
        let gen = RecordingGenerator { idle.fulfill() }
        let turn = TurnManager(model: AnswerModel(), generator: gen)
        turn.paused = false   // no voicedClock (mock/测试环境) → 维持原语义

        turn.handleTranscript(final("あなたの強みを教えてください。"))

        wait(for: [idle], timeout: 0.35)
    }

    @MainActor
    func testStaleVoicedClockIsNotTrusted() {
        setenv("FI_SETTLE_MS", "600", 1)
        let idle = expectation(description: "no early commit on a stale clock")
        idle.isInverted = true
        let gen = RecordingGenerator { idle.fulfill() }
        let turn = TurnManager(model: AnswerModel(), generator: gen)
        turn.paused = false
        // 6s 前的时间戳（>5s 信任窗）：说明 VAD 漏检了这句话，抵扣必须作废。
        turn.latency.voicedClock = { DispatchTime.now().uptimeNanoseconds &- 6_000_000_000 }

        turn.handleTranscript(final("あなたの強みを教えてください。"))

        wait(for: [idle], timeout: 0.35)
    }
}
