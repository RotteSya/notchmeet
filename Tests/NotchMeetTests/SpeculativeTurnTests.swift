import XCTest
import os
@testable import notchmeet

/// Speculative open-on-interim: delayed persist, 350ms debounce, coverage confirm.
final class SpeculativeTurnTests: XCTestCase {

    private final class RecordingGenerator: AnswerGenerator, @unchecked Sendable {
        private let asked = OSAllocatedUnfairLock(initialState: [String]())
        private let onGenerate: @Sendable () -> Void
        init(onGenerate: @escaping @Sendable () -> Void = {}) { self.onGenerate = onGenerate }
        var questions: [String] { asked.withLock { $0 } }

        func generate(_ req: GenRequest, epoch: Int, onDelta: @escaping (String) -> Void) async throws {
            asked.withLock { $0.append(req.question) }
            onDelta("我的优势是把复杂问题拆开再落地。")
            onGenerate()
        }
    }

    private func interim(_ text: String) -> Transcript {
        Transcript(text: text, isFinal: false, confidence: 0.8)
    }
    private func final(_ text: String) -> Transcript {
        Transcript(text: text, isFinal: true, confidence: 0.95)
    }

    override func setUp() {
        super.setUp()
        setenv("FI_SPECULATE_MS", "40", 1)
        setenv("FI_SETTLE_MS", "50", 1)
    }

    override func tearDown() {
        unsetenv("FI_SPECULATE_MS")
        unsetenv("FI_SETTLE_MS")
        super.tearDown()
    }

    @MainActor
    private func chineseTurn(_ gen: RecordingGenerator,
                             knowledge: KnowledgeProvider = NullKnowledge(),
                             onRecorded: ((String) -> Void)? = nil) -> TurnManager {
        let tm = TurnManager(model: AnswerModel(), generator: gen, knowledge: knowledge)
        tm.interviewLanguage = .chinese
        tm.paused = false
        tm.onTurnRecorded = { q, _, _ in onRecorded?(q) }
        return tm
    }

    @MainActor
    func testCompleteInterimStartsATurnBeforeFinal() {
        let exp = expectation(description: "speculative generate")
        let gen = RecordingGenerator { exp.fulfill() }
        let turn = chineseTurn(gen)
        turn.handleTranscript(interim("请介绍一下你自己吗"))
        wait(for: [exp], timeout: 0.4)
        XCTAssertEqual(gen.questions.count, 1)
        XCTAssertTrue(gen.questions[0].contains("介绍一下你自己"))
    }

    @MainActor
    func testMatchingFinalDoesNotStartASecondTurn() {
        let first = expectation(description: "first generate")
        let gen = RecordingGenerator { first.fulfill() }
        let turn = chineseTurn(gen)
        let q = "请介绍一下你自己吗"
        turn.handleTranscript(interim(q))
        wait(for: [first], timeout: 0.4)
        turn.handleTranscript(final(q))
        let pause = expectation(description: "settle after confirm")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { pause.fulfill() }
        wait(for: [pause], timeout: 0.3)
        XCTAssertEqual(gen.questions.count, 1, "covered final must reuse the speculative turn")
    }

    @MainActor
    func testUncoveredSecondQuestionRestarts() {
        let exp = expectation(description: "two generates")
        exp.expectedFulfillmentCount = 2
        let gen = RecordingGenerator { exp.fulfill() }
        let turn = chineseTurn(gen)
        turn.handleTranscript(interim("请介绍一下你自己吗"))
        // let spec fire
        let fired = expectation(description: "spec fired")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { fired.fulfill() }
        wait(for: [fired], timeout: 0.3)
        turn.handleTranscript(final("请介绍一下你自己吗 另外你的项目经历是什么"))
        wait(for: [exp], timeout: 0.6)
        XCTAssertEqual(gen.questions.count, 2, "Q1+Q2 must not reuse a Q1 speculation")
        XCTAssertTrue(gen.questions.last?.contains("项目经历") == true)
    }

    @MainActor
    func testBackchannelInterimDoesNotSpeculate() {
        let idle = expectation(description: "no generate")
        idle.isInverted = true
        let gen = RecordingGenerator { idle.fulfill() }
        let turn = chineseTurn(gen)
        turn.handleTranscript(interim("好的，我明白了"))
        wait(for: [idle], timeout: 0.2)
        XCTAssertTrue(gen.questions.isEmpty)
    }

    @MainActor
    func testVolatileInterimDebouncesToOneFire() {
        let exp = expectation(description: "one generate")
        let gen = RecordingGenerator { exp.fulfill() }
        let turn = chineseTurn(gen)
        turn.handleTranscript(interim("请介绍一下你自己吗"))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.015) {
            turn.handleTranscript(self.interim("请介绍一下你自己吗？"))
        }
        wait(for: [exp], timeout: 0.4)
        XCTAssertEqual(gen.questions.count, 1, "debounce must collapse volatile complete interims")
    }

    @MainActor
    func testFactQuickAnswerDoesNotRecordUntilFinalConfirmed() {
        let dir = NSTemporaryDirectory() + "spec-facts-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        setenv("FI_FACTS", dir + "/facts.json", 1)
        defer {
            unsetenv("FI_FACTS")
            try? FileManager.default.removeItem(atPath: dir)
        }
        let facts = FactStore()
        XCTAssertTrue(facts.save(FactSheet(profile: nil, experiences: [], motivations: [],
                                           notes: ["期望薪资: 30万"])))

        var recorded: [String] = []
        let gen = RecordingGenerator()
        let turn = chineseTurn(gen, knowledge: facts) { recorded.append($0) }
        let q = "你的期望薪资是多少"
        turn.handleTranscript(interim(q))
        let specWait = expectation(description: "spec window")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { specWait.fulfill() }
        wait(for: [specWait], timeout: 0.3)
        XCTAssertTrue(recorded.isEmpty, "speculative fact-quick must not persist yet: \(recorded)")
        turn.handleTranscript(final(q))
        let settled = expectation(description: "settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { settled.fulfill() }
        wait(for: [settled], timeout: 0.4)
        XCTAssertEqual(recorded.count, 1, "confirming final must persist exactly once")
    }

    @MainActor
    func testPendingFinalPlusInterimIsTheSpeculativeCandidate() {
        let exp = expectation(description: "generate")
        let gen = RecordingGenerator { exp.fulfill() }
        let turn = chineseTurn(gen)
        // Deepgram-style: a statement final, then the real question as interim.
        turn.handleTranscript(final("我先介绍一下岗位情况。"))
        turn.handleTranscript(interim("你怎么看这个方向呢"))
        wait(for: [exp], timeout: 0.4)
        let q = gen.questions.first ?? ""
        XCTAssertTrue(q.contains("岗位情况") && q.contains("你怎么看"),
                      "speculation must see pendingQ + interim, not the naked interim: \(q)")
    }
}
