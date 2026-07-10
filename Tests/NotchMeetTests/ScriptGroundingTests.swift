import XCTest
@testable import notchmeet

/// F3: live 生成的兜底 grounding。旧实现按稿子顺序截 1500 字 —— 实测 JINS 稿（48 条、
/// 1.1 万字）只有前 5 条能进 grounding，路由一失手，被问条目的准备答案 LLM 根本看不见，
/// 只能现编。新实现按「与当前问题的相关度」选条目。
final class ScriptGroundingTests: XCTestCase {
    private var dir: String!

    override func setUp() {
        super.setUp()
        dir = NSTemporaryDirectory() + "sg-\(UUID().uuidString)"
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: dir)
        super.tearDown()
    }

    /// 40 条冗长条目 + 1 条相关条目排在最后 —— 相关条目必须进 grounding。
    func testRelevantEntryLateInLongScriptIsIncluded() {
        let store = ScriptStore(directory: dir)
        var entries = (1...40).map { i in
            BankEntry(id: "pad\(i)", intent: "パディング質問その\(i)",
                      question: "パディング質問その\(i)",
                      answer: String(repeating: "これは長い回答です。", count: 30), locked: true)
        }
        entries.append(BankEntry(id: "gold", intent: "在留資格は大丈夫ですか",
                                 question: "在留資格は大丈夫ですか",
                                 answer: "はい、問題ございません。2027年5月まで有効です。", locked: true))
        store.add(name: "test", entries: entries)

        let block = store.contextBlock(for: "在留資格は問題ないですか。")
        XCTAssertTrue(block.contains("在留資格は大丈夫ですか"), "relevant question missing")
        XCTAssertTrue(block.contains("2027年5月まで有効です"), "relevant answer missing")
    }

    /// 预算仍然生效（3s SLA 的上下文预算不能爆）。
    func testBudgetIsRespected() {
        let store = ScriptStore(directory: dir)
        let entries = (1...40).map { i in
            BankEntry(id: "e\(i)", intent: "質問\(i)", question: "質問\(i)",
                      answer: String(repeating: "回答。", count: 100), locked: true)
        }
        store.add(name: "test", entries: entries)
        XCTAssertLessThanOrEqual(store.contextBlock(for: "質問1について").count, 1500)
    }

    /// 不再拦腰截断：进入 grounding 的条目答案必须完整。
    func testIncludedEntriesAreNeverTruncatedMidAnswer() {
        let store = ScriptStore(directory: dir)
        let marker = "回答の最後の一文はここで終わります。"
        let entries = (1...6).map { i in
            BankEntry(id: "e\(i)", intent: "質問\(i)", question: "質問\(i)",
                      answer: String(repeating: "本文。", count: 90) + marker, locked: true)
        }
        store.add(name: "test", entries: entries)

        let block = store.contextBlock(for: "質問3について教えてください")
        // 每个出现在 block 里的条目，其答案结尾 marker 必须同样出现相同次数。
        let headings = block.components(separatedBy: "## ").count - 1
        let completeAnswers = block.components(separatedBy: marker).count - 1
        XCTAssertGreaterThan(headings, 0)
        XCTAssertEqual(headings, completeAnswers, "an included entry was cut mid-answer")
    }

    func testEmptyScriptYieldsEmptyBlock() {
        let store = ScriptStore(directory: dir)
        XCTAssertEqual(store.contextBlock(for: "自己紹介をお願いします"), "")
    }
}
