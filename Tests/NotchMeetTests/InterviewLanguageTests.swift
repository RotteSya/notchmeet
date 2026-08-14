import XCTest
@testable import notchmeet

/// 中文面试语言（`InterviewLanguage.chinese`）的接线测试：STT 语言码、提示词契约、
/// 路由器指代检测、事实即答成句——每一处此前写死日语的接点都要能按设置切换，
/// 且默认值必须保持 `.japanese`（既有安装行为不变）。
final class InterviewLanguageTests: XCTestCase {

    private var savedLanguage: String?

    override func setUp() {
        super.setUp()
        savedLanguage = UserDefaults.standard.string(forKey: "nm_interview_language")
    }

    override func tearDown() {
        if let v = savedLanguage {
            UserDefaults.standard.set(v, forKey: "nm_interview_language")
        } else {
            UserDefaults.standard.removeObject(forKey: "nm_interview_language")
        }
        super.tearDown()
    }

    // MARK: - Settings

    func testDefaultInterviewLanguageIsJapanese() {
        UserDefaults.standard.removeObject(forKey: "nm_interview_language")
        XCTAssertEqual(Settings.interviewLanguage, .japanese)
    }

    func testInterviewLanguagePersists() {
        Settings.interviewLanguage = .chinese
        XCTAssertEqual(Settings.interviewLanguage, .chinese)
        XCTAssertEqual(UserDefaults.standard.string(forKey: "nm_interview_language"), "zh")
    }

    func testUnknownStoredValueFallsBackToJapanese() {
        UserDefaults.standard.set("ko", forKey: "nm_interview_language")
        XCTAssertEqual(Settings.interviewLanguage, .japanese)
    }

    // MARK: - STT 语言码

    func testSttLanguageCodes() {
        XCTAssertEqual(InterviewLanguage.japanese.deepgramCode, "ja")
        XCTAssertEqual(InterviewLanguage.chinese.deepgramCode, "zh-CN")
        XCTAssertEqual(InterviewLanguage.japanese.appleLocaleID, "ja-JP")
        XCTAssertEqual(InterviewLanguage.chinese.appleLocaleID, "zh-CN")
    }

    // MARK: - 意图表

    /// 中日意图表逐条对应：预生成条数与计费口径（chargeSecondsPerIntent × 条数）一致。
    func testIntentListsHaveSameLength() {
        XCTAssertEqual(Intents.list(for: .japanese).count, Intents.list(for: .chinese).count)
        XCTAssertEqual(Intents.list(for: .japanese), Intents.list)
    }

    // MARK: - Prompts（中文版承载与日语版同一套约束）

    func testChineseSystemPromptKeepsTheContract() {
        let system = Prompts.system(context: "", language: .chinese)
        XCTAssertTrue(system.contains("只用中文输出"))
        XCTAssertTrue(system.contains("不再重复"), "缺少「不复读」指令")
        XCTAssertTrue(system.contains("按被问到的顺序逐一简洁作答"), "缺少「逐一作答」指令")
        XCTAssertTrue(system.contains("不许只答其中一个而漏掉其余"), "缺少「不得漏答」指令")
        XCTAssertTrue(system.contains("不编造数字、经历、专有名词"))
        XCTAssertTrue(system.contains("不同经历、不同语境**的原稿不许使用"),
                      "准备稿最优先规则缺少换经历例外条款")
    }

    func testChineseUserPromptFramesHistoryWithChineseLabels() {
        let user = Prompts.user(question: "那个活动的成果是什么？",
                                history: "面试官: 学生时代最投入的是什么？\n建议回答: 我最投入的是社团活动。",
                                language: .chinese)
        XCTAssertTrue(user.contains("此前的对话"))
        XCTAssertTrue(user.contains("「面试官」是实际被问到的问题"))
        XCTAssertTrue(user.contains("「建议回答」是你刚才给出的文面"))
    }

    func testChineseDeicticQuestionGetsReferenceInstruction() {
        let user = Prompts.user(question: "你刚才说的那段经历，能用在我们公司吗？",
                                history: "面试官: 为什么去读 MBA？\n建议回答: 我系统性地重学了数据分析。",
                                language: .chinese)
        XCTAssertTrue(user.contains("也不许换成讲另一段经历的文面"))
    }

    func testChineseDeicticWithoutHistoryOmitsInstruction() {
        let user = Prompts.user(question: "你刚才说的那段经历，能用在我们公司吗？",
                                history: "", language: .chinese)
        XCTAssertFalse(user.contains("也不许换成讲另一段经历的文面"))
    }

    // MARK: - Router

    func testDeicticDetectsChineseMarkers() {
        XCTAssertTrue(LLMRouter.isDeictic("刚才提到的项目，你负责哪部分？"))
        XCTAssertTrue(LLMRouter.isDeictic("那段经历教会了你什么？"))
        // 「那么」是话轮开场语，不算指代——与日语「それでは」同一判定。
        XCTAssertFalse(LLMRouter.isDeictic("那么，请做个自我介绍。"))
    }

    func testChineseRouterPromptListsChineseIntents() {
        let system = LLMRouter.systemPrompt(language: .chinese)
        XCTAssertTrue(system.contains("自我介绍"))
        XCTAssertTrue(system.contains("反向提问"))
        XCTAssertTrue(system.contains("**不同经历必须 null**"), "经历一致性规则缺失")
    }

    func testChineseCandidateBlockUsesChineseLabels() {
        let block = LLMRouter.candidateBlock(
            [BankEntry(id: "a", intent: "自我介绍", question: "请自我介绍",
                       answer: "面试官您好，我叫王明。", locked: true, format: .spoken)],
            language: .chinese)
        XCTAssertTrue(block.contains("[0] 问题: 请自我介绍"))
        XCTAssertTrue(block.contains("回答开头: 面试官您好"))
    }

    // MARK: - 事实即答（中文成句）

    private var dir: String!

    private func store(_ notesBlock: String) -> FactStore {
        dir = NSTemporaryDirectory() + "il-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        setenv("FI_FACTS", dir + "/facts.json", 1)
        addTeardownBlock { [dir] in
            unsetenv("FI_FACTS")
            if let dir { try? FileManager.default.removeItem(atPath: dir) }
        }
        let s = FactStore()
        XCTAssertTrue(s.save(FactsTextFormat.parse("# メモ\n" + notesBlock)))
        return FactStore()
    }

    func testChineseSalaryAnswerUsesGenericSentence() {
        let facts = store("期望薪资: 30万人民币")
        XCTAssertEqual(FactQuickAnswer.answer(for: "您的期望薪资是多少？", facts: facts,
                                              language: .chinese),
                       "期望薪资是30万人民币。")
    }

    func testChineseStartDateAnswer() {
        let facts = store("入职时间: 2027年4月")
        XCTAssertEqual(FactQuickAnswer.answer(for: "你什么时候能来上班？", facts: facts,
                                              language: .chinese),
                       "2027年4月起可以入职。")
    }

    /// 值已是完整一句时原样返回，不套模板（与日语路径同一契约）。
    func testChineseCompleteSentenceValueIsUsedAsIs() {
        let facts = store("期望薪资: 按贵司的薪酬标准即可。")
        XCTAssertEqual(FactQuickAnswer.answer(for: "期望薪资是多少？", facts: facts,
                                              language: .chinese),
                       "按贵司的薪酬标准即可。")
    }

    // MARK: - UI 文案跟随面试语言

    func testSttStringsFollowInterviewLanguage() {
        Settings.interviewLanguage = .chinese
        XCTAssertTrue(AppStrings(language: .zh).sttLocalUnavailable.contains("本地中文识别不可用"))
        Settings.interviewLanguage = .japanese
        XCTAssertTrue(AppStrings(language: .zh).sttLocalUnavailable.contains("本地日语识别不可用"))
    }
}
