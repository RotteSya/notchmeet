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

    /// 面接官が一息に二問三問聞くのは普通（TurnManager は settle 窓内の finals を
    /// 一つの質問に束ねる）。system prompt に「順に一つずつ答える」指示が無いと、
    /// モデルは最初か最後の一問だけ答えて残りを落とす。
    func testSystemPromptRequiresAnsweringEveryQuestionInAMultiPartAsk() {
        let system = Prompts.system(context: "")
        XCTAssertTrue(system.contains("複数含まれている"), "多问场景没有被提及")
        XCTAssertTrue(system.contains("聞かれた順に一つずつ"), "缺少「逐一作答」指令")
        XCTAssertTrue(system.contains("残りを落とさない"), "缺少「不得漏答」指令")
        // 多问时放宽字数，但仍不许变成条目
        XCTAssertTrue(system.contains("字数の目安を超えてよい"))
        XCTAssertTrue(system.contains("箇条書きにはせず"))
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

    /// 指代型追问必须带「それ＝直前の回答内容」的解释与禁替换指令。
    /// 实机事故：路由侧否决了错误桥接稿之后，生成侧因为 system prompt 的
    /// 「标题相符则照抄准备稿」指令把同一条稿又抄了回来。
    func testDeicticQuestionGetsReferenceResolutionInstruction() {
        let user = Prompts.user(
            question: "それを弊社で生かすことができますか。",
            history: "面接官: なぜMBAに進学したのですか？\n回答案: データ分析を体系的に学び直しました。")
        XCTAssertTrue(user.contains("直前の「回答案」で述べた内容を指しています"))
        XCTAssertTrue(user.contains("別の経験を語る文面に差し替えてはいけません"))
    }

    /// 非指代问题不加这段——避免每一题都背着多余指令。
    func testNonDeicticQuestionOmitsReferenceInstruction() {
        let user = Prompts.user(
            question: "弊社ではどのように貢献できますか。",
            history: "面接官: 自己紹介を。\n回答案: 私の強みは実行力です。")
        XCTAssertFalse(user.contains("差し替えてはいけません"))
    }

    /// 无 history 时即便问句含指代词也不加（没有可指的对象）。
    func testDeicticWithoutHistoryOmitsReferenceInstruction() {
        let user = Prompts.user(question: "それを弊社で生かすことができますか。", history: "")
        XCTAssertFalse(user.contains("差し替えてはいけません"))
    }

    /// system prompt 的「准备稿最优先」规则必须带例外条款——不带的话，
    /// grounding 里任何标题相似的错位稿都会被无条件照抄。
    func testSystemPromptScriptPrecedenceHasContextException() {
        let system = Prompts.system(context: "何か")
        XCTAssertTrue(system.contains("別の経験・別の文脈**を語る原稿は使わない"))
    }

    /// Live 路径的 system 必须整场稳定：空 context 不得再塞事实段。
    func testEmptyContextKeepsSystemFreeOfFactDump() {
        let system = Prompts.system()
        XCTAssertFalse(system.contains("# 事実情報（ES/自己分析）"))
        XCTAssertTrue(system.contains("事実情報"))   // 规则仍点名这块素材
        let user = Prompts.user(question: "強みは？", history: "", context: "強み: 実行力")
        XCTAssertTrue(user.contains("# 事実情報（ES/自己分析）"))
        XCTAssertTrue(user.contains("強み: 実行力"))
    }
}
