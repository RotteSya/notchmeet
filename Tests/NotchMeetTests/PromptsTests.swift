import XCTest
@testable import notchmeet

final class PromptsTests: XCTestCase {
    /// Stage A: the system prompt must tell the model NOT to repeat already-stated
    /// achievements and to go deeper on a follow-up (the 复读 bug fix).
    func testSystemPromptForbidsRepetitionAndAsksToDeepen() {
        let system = Prompts.system(context: "")
        XCTAssertTrue(system.contains("繰り返さない"))
        XCTAssertTrue(system.contains("深掘り"))
    }

    /// Stage A: with history present, the user prompt explains what the running 流れ is FOR
    /// (dedup + deepen) instead of dumping it as bare context.
    func testUserPromptFramesHistoryForDedup() {
        let user = Prompts.user(question: "その活動の成果は？",
                                history: "面接官: 学生時代に力を入れたことは？\n回答案: ゼミ活動に力を入れました。")
        XCTAssertTrue(user.contains("これまでの流れ"))
        XCTAssertTrue(user.contains("繰り返さず"))
        XCTAssertTrue(user.contains("深掘り"))
    }

    /// Stage B: history answers must be labeled as a prior *suggestion*, not as what the
    /// candidate actually said — the app only ever hears the interviewer.
    func testUserPromptLabelsHistoryAnswersAsSuggestions() {
        let user = Prompts.user(question: "強みは？",
                                history: "面接官: 自己紹介を。\n回答案: 私の強みは実行力です。")
        XCTAssertTrue(user.contains("回答案"))
        XCTAssertTrue(user.contains("候補者がこの通り話したとは限りません"))
    }

    /// No history → no 流れ block at all, keeping the first-question prompt clean.
    func testUserPromptOmitsHistoryBlockWhenEmpty() {
        let user = Prompts.user(question: "自己紹介をお願いします。", history: "")
        XCTAssertFalse(user.contains("これまでの流れ"))
    }
}
