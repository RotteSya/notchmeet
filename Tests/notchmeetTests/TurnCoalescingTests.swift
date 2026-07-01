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
    func testHesitationMidQuestionCoalescesViaTheLongerWindow() {
        setenv("FI_SETTLE_MS", "40", 1)        // complete-looking (。か) → commit fast
        setenv("FI_SETTLE_MAX_MS", "300", 1)   // trails off mid-clause → wait longer
        let exp = expectation(description: "one turn")
        let gen = RecordingGenerator { exp.fulfill() }
        let turn = TurnManager(model: AnswerModel(), generator: gen)
        turn.paused = false

        // 「…なぜ」で一旦切れる（未完）。短い窓(40ms)では確定せず、本題を待つ。
        turn.handleTranscript(final("はい、あの、なぜ"))
        // 120ms 後（短い窓は過ぎ／長い窓300msの内側）に本題が続く → 1ターンに連結。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            turn.handleTranscript(self.final("当社を選びましたか。"))
        }

        wait(for: [exp], timeout: 1.0)
        XCTAssertEqual(gen.questions.count, 1, "a mid-clause hesitation must not split the question")
        let q = gen.questions.first ?? ""
        XCTAssertTrue(q.contains("なぜ") && q.contains("選びましたか"), "both halves coalesced: \(q)")
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

    /// The reported bug: 面接官 states a view, pauses to formulate, THEN asks. A statement that ends
    /// in 「。」 is grammatically complete but is NOT the end of the turn — it's setup. It must take the
    /// long window and coalesce with the 本題, not commit alone. (Old `looksComplete` gave 「。」 the
    /// short window, so the setup committed during the pause and the real question lost its context.)
    @MainActor
    func testCompleteStatementWaitsForItsFollowUpQuestion() {
        setenv("FI_SETTLE_MS", "40", 1)        // a completed question/request commits fast…
        setenv("FI_SETTLE_MAX_MS", "300", 1)   // …but a bare statement must wait for the 本題
        let exp = expectation(description: "one turn")
        let gen = RecordingGenerator { exp.fulfill() }
        let turn = TurnManager(model: AnswerModel(), generator: gen)
        turn.paused = false

        // 意見の表明（句点で完結・質問ではない）。旧ロジックは 40ms で確定＝分割していた。
        turn.handleTranscript(final("なるほど、それは一理あると思います。"))
        // 150ms 後（短い窓40msは越え／長い窓300msの内側）に本題 → 本来は1ターン。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            turn.handleTranscript(self.final("その点、あなたはどう思いますか。"))
        }

        wait(for: [exp], timeout: 1.0)
        XCTAssertEqual(gen.questions.count, 1, "a complete statement is setup, not a turn — it must not split from its question")
        let q = gen.questions.first ?? ""
        XCTAssertTrue(q.contains("一理あると思います") && q.contains("どう思いますか"), "setup + 本題 coalesced: \(q)")
    }

    /// Safety net for when the pause is longer than even the long window: the setup DID commit, but the
    /// 本題 lands within `mergeGrace`, so it is folded back and the answered question carries its setup.
    @MainActor
    func testStatementThenPausedQuestionRecallMerges() {
        setenv("FI_SETTLE_MS", "40", 1)
        setenv("FI_SETTLE_MAX_MS", "80", 1)     // statement commits before the follow-up (pause > window)
        setenv("FI_MERGE_GRACE_MS", "600", 1)   // …but the 本題 lands inside the grace → fold back
        let both = expectation(description: "setup turn, then a merged turn")
        both.expectedFulfillmentCount = 2
        let gen = RecordingGenerator { both.fulfill() }
        let turn = TurnManager(model: AnswerModel(), generator: gen)
        turn.paused = false

        // 表明が先に確定してしまう（間＞窓）。その直後（間＜grace）に本題 → リコール・マージで開き直す。
        turn.handleTranscript(final("実際の現場では課題があると感じています。"))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {   // > 80ms window, < 600ms grace
            turn.handleTranscript(self.final("その点、どうお考えですか。"))
        }

        wait(for: [both], timeout: 2.0)
        // 開き直したターンは〔表明＋本題〕を1問として答える。旧挙動は本題だけを裸で答えていた。
        let merged = gen.questions.last ?? ""
        XCTAssertTrue(merged.contains("課題があると感じています") && merged.contains("どうお考えですか"),
                      "the real question must be answered WITH its setup, not stripped: \(merged)")
        XCTAssertEqual(gen.questions.count, 2, "setup committed, then the follow-up reopened it as one merged turn")
    }

    /// Real case from the 2026-07-01 interview (@27:38, transcribed on-device): the interviewer
    /// prefaces ("…気になったのは、志望動機のところ…") and, after a ~1.1s pause, asks the actual
    /// question ("なぜ車載電池の当社を選んだのか"). Measured within-turn setup→question pauses in that
    /// interview ran ≈0.7–1.4s — longer than the short window, so the declarative preface must take
    /// the long window and stay attached to its question instead of being answered on its own.
    @MainActor
    func testRealInterviewPrefaceThenQuestionStaysOneTurn() {
        setenv("FI_SETTLE_MS", "40", 1)        // a completed question commits fast…
        setenv("FI_SETTLE_MAX_MS", "260", 1)   // …but the declarative preface waits for 本題 (≈1.8s, scaled)
        let exp = expectation(description: "one turn")
        let gen = RecordingGenerator { exp.fulfill() }
        let turn = TurnManager(model: AnswerModel(), generator: gen)
        turn.paused = false

        turn.handleTranscript(final("少し気になったのは、志望動機のところです。"))     // 前置き（陳述、。で完結）
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.13) {                    // ~1.1s の思考の間（縮尺）
            turn.handleTranscript(self.final("なぜ車載電池の当社を選んだのですか。"))   // 本題
        }

        wait(for: [exp], timeout: 1.0)
        XCTAssertEqual(gen.questions.count, 1, "an interviewer's preface + question is ONE turn, not two")
        let q = gen.questions.first ?? ""
        XCTAssertTrue(q.contains("志望動機") && q.contains("なぜ車載電池"),
                      "the answered question must carry its preface: \(q)")
    }
}
