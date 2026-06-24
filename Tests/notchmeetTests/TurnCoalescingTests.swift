import XCTest
import os
@testable import notchmeet

/// Locks in the utterance-coalescing fix: a 寒暄＋本題 utterance that Deepgram splits into
/// several finals must become ONE turn, and standalone greetings/相槌 must never trigger one.
final class TurnCoalescingTests: XCTestCase {
    /// Records each question the generator is asked to answer (= one started turn).
    private final class RecordingGenerator: AnswerGenerator, @unchecked Sendable {
        private let asked = OSAllocatedUnfairLock(initialState: [String]())
        private let onGenerate: @Sendable () -> Void
        init(onGenerate: @escaping @Sendable () -> Void) { self.onGenerate = onGenerate }
        var questions: [String] { asked.withLock { $0 } }

        func generate(_ req: GenRequest, epoch: Int, onDelta: @escaping (String) -> Void) async throws {
            asked.withLock { $0.append(req.question) }
            onDelta("はい、私の強みは実行力です。")  // trips hasSpeakableOpening → commits
            onGenerate()
        }
    }

    private func final(_ text: String) -> Transcript { Transcript(text: text, isFinal: true, confidence: 0.95) }

    override func setUp() {
        super.setUp()
        setenv("FI_SETTLE_MS", "60", 1)  // read at TurnManager init; keep the wait short & deterministic
    }

    @MainActor
    func testCoalescesGreetingAndQuestionIntoOneTurn() {
        let exp = expectation(description: "one turn")
        let gen = RecordingGenerator { exp.fulfill() }
        let turn = TurnManager(model: AnswerModel(), generator: gen)
        turn.paused = false

        // 本題が句点で2つの final に割れても、settleWindow 内なら 1 ターンに連結される。
        turn.handleTranscript(final("本日のテーマについてお聞きします。"))
        turn.handleTranscript(final("あなたの強みを教えてください。"))

        wait(for: [exp], timeout: 1.0)
        XCTAssertEqual(gen.questions.count, 1, "split finals within the settle window must be ONE turn")
        let q = gen.questions.first ?? ""
        XCTAssertTrue(q.contains("本日のテーマ"), "first clause kept")
        XCTAssertTrue(q.contains("強みを教えてください"), "second clause appended")
    }

    @MainActor
    func testStandaloneGreetingDoesNotTriggerATurn() {
        let idle = expectation(description: "no turn within the window")
        idle.isInverted = true
        let gen = RecordingGenerator { idle.fulfill() }
        let turn = TurnManager(model: AnswerModel(), generator: gen)
        turn.paused = false

        turn.handleTranscript(final("よろしくお願いします。"))
        turn.handleTranscript(final("なるほど。"))

        wait(for: [idle], timeout: 0.3)
        XCTAssertTrue(gen.questions.isEmpty, "greetings / 相槌 alone must not start a turn")
    }

    @MainActor
    func testSeparateUtterancesAreSeparateTurns() {
        let exp = expectation(description: "two turns")
        exp.expectedFulfillmentCount = 2
        let gen = RecordingGenerator { exp.fulfill() }
        let turn = TurnManager(model: AnswerModel(), generator: gen)
        turn.paused = false

        turn.handleTranscript(final("自己紹介をお願いします。"))
        // settleWindow(60ms) を十分に越えてから次の質問 → 別ターン。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            turn.handleTranscript(self.final("志望動機を教えてください。"))
        }

        wait(for: [exp], timeout: 1.5)
        XCTAssertEqual(gen.questions.count, 2, "utterances separated by silence must be distinct turns")
    }
}
