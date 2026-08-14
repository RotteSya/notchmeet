import XCTest
@testable import notchmeet

/// 中文面试语言（`InterviewLanguage.chinese`）的接线测试：STT 语言码、提示词契约、
/// 路由器指代检测、事实即答成句——每一处此前写死日语的接点都要能按设置切换，
/// 且默认值必须保持 `.japanese`（既有安装行为不变）。
///
/// 语言偏好经 `Settings.languageDefaults` 存取；这里换成独立 suite——它是本套件
/// 会真实改写的全局状态，并行测试进程共享持久域，不隔离会让「zh」泄漏进
/// 断言默认日语的兄弟套件（PromptsTests / LocalizationTests …）。
final class InterviewLanguageTests: XCTestCase {

    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "nm-test-\(UUID().uuidString)"
        Settings.languageDefaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        Settings.languageDefaults.removePersistentDomain(forName: suiteName)
        Settings.languageDefaults = .standard
        super.tearDown()
    }

    // MARK: - Settings

    func testDefaultInterviewLanguageIsJapanese() {
        XCTAssertEqual(Settings.interviewLanguage, .japanese)
    }

    func testInterviewLanguagePersists() {
        Settings.interviewLanguage = .chinese
        XCTAssertEqual(Settings.interviewLanguage, .chinese)
        XCTAssertEqual(Settings.languageDefaults.string(forKey: "nm_interview_language"), "zh")
    }

    func testUnknownStoredValueFallsBackToJapanese() {
        Settings.languageDefaults.set("ko", forKey: "nm_interview_language")
        XCTAssertEqual(Settings.interviewLanguage, .japanese)
    }

    /// setter 自己广播（与 answerTextSize 同一模式）：任何写入者都不可能忘记通知。
    func testSettingInterviewLanguagePostsChangeNotification() {
        let exp = expectation(forNotification: .nmInterviewLanguageChanged, object: nil)
        Settings.interviewLanguage = .chinese
        wait(for: [exp], timeout: 1.0)
    }

    /// 预生成库的语言戳：默认日语（既有安装的库全是旧日语版本）。
    func testAnswerBankLanguageDefaultsToJapanese() {
        XCTAssertEqual(Settings.answerBankLanguage, .japanese)
        Settings.answerBankLanguage = .chinese
        XCTAssertEqual(Settings.answerBankLanguage, .chinese)
    }

    // MARK: - STT 语言码

    func testSttLanguageCodes() {
        XCTAssertEqual(InterviewLanguage.japanese.deepgramCode, "ja")
        XCTAssertEqual(InterviewLanguage.chinese.deepgramCode, "zh-CN")
        XCTAssertEqual(InterviewLanguage.japanese.appleLocaleID, "ja-JP")
        XCTAssertEqual(InterviewLanguage.chinese.appleLocaleID, "zh-CN")
    }

    /// 关键词 boost 必须与识别语言同语种：中文会话不下发日语就活词表。
    func testDeepgramBoostKeywordsFollowLanguage() {
        XCTAssertFalse(DeepgramSttClient.boostKeywords(for: "ja").isEmpty)
        XCTAssertTrue(DeepgramSttClient.boostKeywords(for: "zh-CN").isEmpty)
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
        XCTAssertFalse(system.contains("综合岗位"), "中文不再套用就活综合职角色")
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

    /// 中文没有假名分词，整串比对的内容词重叠恒为 0——必须按 bigram 切分，
    /// 否则指代型追问的正确原稿命中会被无条件否决（本次修复的回归锚点）。
    func testChineseDeicticVetoSparesSameExperienceMatch() {
        let history = "面试官: 请谈谈你的实习。\n建议回答: 我在实习期间负责数据分析，独立完成了三个报表。"
        let match = RouteDecision(intent: "实习",
                                  matchedAnswer: "那段实习中我主要负责数据分析，最大的收获是把报表流程自动化。")
        let kept = LLMRouter.vetoingContextMismatch(match,
                                                    question: "刚才提到的那段经历，能用在贵司吗？",
                                                    history: history, language: .chinese)
        XCTAssertNotNil(kept.matchedAnswer, "同一段经历的命中被误杀")
    }

    /// 反向：讲另一段经历的稿件仍要被否决（否决线的本职）。
    func testChineseDeicticVetoKillsDifferentExperienceMatch() {
        let history = "面试官: 请谈谈你的实习。\n建议回答: 我在实习期间负责数据分析，独立完成了三个报表。"
        let wrong = RouteDecision(intent: "留学",
                                  matchedAnswer: "在留学期间我组织了志愿者活动，学会了跨文化沟通。")
        let vetoed = LLMRouter.vetoingContextMismatch(wrong,
                                                      question: "刚才提到的那段经历，能用在贵司吗？",
                                                      history: history, language: .chinese)
        XCTAssertNil(vetoed.matchedAnswer, "另一段经历的错误命中没有被否决")
    }

    // MARK: - 回合门控（中文）

    @MainActor
    private func makeTurnManager(_ language: InterviewLanguage) -> TurnManager {
        let tm = TurnManager(model: AnswerModel(), generator: MockAnswerGenerator())
        tm.interviewLanguage = language
        return tm
    }

    /// 端侧 zh-CN 终稿常无问号；语气助词/疑问词/祈使型必须被识别为「交棒」，
    /// 否则每个中文问题都吃满长 settle 窗口、冲击 3s SLA。
    @MainActor
    func testChineseQuestionsCountAsCompletedPrompts() {
        let tm = makeTurnManager(.chinese)
        XCTAssertTrue(tm.looksLikeCompletedPrompt("请介绍一下你自己"))
        XCTAssertTrue(tm.looksLikeCompletedPrompt("你的期望薪资是多少"))
        XCTAssertTrue(tm.looksLikeCompletedPrompt("你觉得自己最大的优点是什么"))
        XCTAssertTrue(tm.looksLikeCompletedPrompt("方便说说离职原因吗"))
        // 陈述句不是交棒——长窗口等后续本题。
        XCTAssertFalse(tm.looksLikeCompletedPrompt("我们公司主要做跨境电商"))
        // 日语路径不受影响。
        let ja = makeTurnManager(.japanese)
        XCTAssertTrue(ja.looksLikeCompletedPrompt("自己紹介をお願いします"))
        XCTAssertFalse(ja.looksLikeCompletedPrompt("弊社は小売業を営んでおります"))
    }

    /// 中文疑问信号大多在句中：「为什么选择我们**公司**」句尾是名词，尾词表照不到。
    /// 这类问题此前全部吃 1.8s 长窗口——每问比短窗口多白等约 1 秒。
    @MainActor
    func testChineseMidSentenceInterrogativesCountAsCompletedPrompts() {
        let tm = makeTurnManager(.chinese)
        XCTAssertTrue(tm.looksLikeCompletedPrompt("为什么选择我们公司"))
        XCTAssertTrue(tm.looksLikeCompletedPrompt("你在项目里负责哪个模块"))
        XCTAssertTrue(tm.looksLikeCompletedPrompt("你觉得这个方案有什么风险"))
        XCTAssertTrue(tm.looksLikeCompletedPrompt("你是不是更倾向于后端方向"))
        XCTAssertTrue(tm.looksLikeCompletedPrompt("有没有带过团队"))
        XCTAssertTrue(tm.looksLikeCompletedPrompt("这个指标你们是怎么定的"))
        // 祈使型提问常不带「请」，但必须锚定第二人称/「自己」。
        XCTAssertTrue(tm.looksLikeCompletedPrompt("介绍一下你自己"))
        XCTAssertTrue(tm.looksLikeCompletedPrompt("说说你最有成就感的项目"))
        // 疑问词只查最后一个分句：铺垫半句里的疑问词不算交棒。分隔符必须含句读
        // 与空格——pendingQ 是多条终稿用空格拼接的累积体，只认逗号时收窄整体失效。
        XCTAssertFalse(tm.looksLikeCompletedPrompt("大家都问为什么，我先说一下我们的安排"))
        XCTAssertFalse(tm.looksLikeCompletedPrompt("大家都问为什么。我先介绍一下公司情况"))
        XCTAssertFalse(tm.looksLikeCompletedPrompt("很多人问为什么加班 我先说一下我们的节奏"))
        // 面试官的开场陈述/第一人称祈使不是提问。
        XCTAssertFalse(tm.looksLikeCompletedPrompt("我先介绍一下我们团队"))
        XCTAssertFalse(tm.looksLikeCompletedPrompt("我先介绍一下自己，我是技术负责人"))
        // 陈述用法排除词与词表绑定（没什么/没有什么/几乎/不怎么/哪怕）。
        XCTAssertFalse(tm.looksLikeCompletedPrompt("我几乎什么都做过"))
        XCTAssertFalse(tm.looksLikeCompletedPrompt("这个岗位没有什么硬性要求"))
        XCTAssertFalse(tm.looksLikeCompletedPrompt("时间上没什么冲突"))
        XCTAssertFalse(tm.looksLikeCompletedPrompt("我们不怎么加班"))
        XCTAssertFalse(tm.looksLikeCompletedPrompt("哪怕项目再紧我们也没延期过"))
        // 量词陈述不收（我做了几年后端）——几个/几年/几次刻意不在词表里。
        XCTAssertFalse(tm.looksLikeCompletedPrompt("我在这家公司做了几年后端"))
        // 3 字短问不算交棒：更可能是长问题在停顿处切出的头一截，长窗口等后半句。
        XCTAssertFalse(tm.looksLikeCompletedPrompt("为什么"))
    }

    /// 中文 3 字短追问（端侧终稿常无问号）是真问题，不许被 4 字长度闸当寒暄吞掉。
    @MainActor
    func testChineseShortFollowUpsAreMeaningful() {
        let tm = makeTurnManager(.chinese)
        XCTAssertTrue(tm.isMeaningfulQuestion("为什么"))
        XCTAssertTrue(tm.isMeaningfulQuestion("然后呢"))
        XCTAssertTrue(tm.isMeaningfulQuestion("比如呢"))
        XCTAssertTrue(tm.isMeaningfulQuestion("多少？"))
        // 非疑问短语维持原闸。
        XCTAssertFalse(tm.isMeaningfulQuestion("谢谢。"))
        XCTAssertFalse(tm.isMeaningfulQuestion("收到"))
        XCTAssertFalse(tm.isMeaningfulQuestion("很好"))
        // 含疑问字形的 3 字口语填充仍要滤掉（skip 表对 <4 字不可达，靠 zhShortFillers）。
        XCTAssertFalse(tm.isMeaningfulQuestion("怎么说"))
        XCTAssertFalse(tm.isMeaningfulQuestion("是不是"))
        // 日语 <4 字维持原闸——用 3 字样本，2 字的「なぜ」在长度闸就被挡、
        // 走不到语言判别分支，锁不住这里要锁的行为。
        let ja = makeTurnManager(.japanese)
        XCTAssertFalse(ja.isMeaningfulQuestion("どうぞ"))
    }

    /// 中文面试的事实块标签必须与中文 system prompt 的锚点（「事实信息」）同语言：
    /// 日语标签会让「只以事实信息为依据」的指令与素材对不上号。
    func testFactContextLabelsFollowInterviewLanguage() {
        let s = store("希望年収: 400万円")
        let zh = s.context(for: "", language: .chinese)
        XCTAssertTrue(zh.contains("自我分析笔记:"), "中文面试要用中文标签: \(zh)")
        XCTAssertFalse(zh.contains("自己分析メモ"), "中文面试不许出现日语标签")
        let ja = s.context(for: "", language: .japanese)
        XCTAssertTrue(ja.contains("自己分析メモ:"), "日语标签维持原行为")
    }

    func testChineseSpeakableOpeningIsShorterThanJapanese() {
        let mid = String(repeating: "我", count: 24)
        XCTAssertTrue(TurnManager.hasSpeakableOpening(mid, language: .chinese),
                      "24 个汉字已够开口，不必等句号")
        XCTAssertFalse(TurnManager.hasSpeakableOpening(mid, language: .japanese),
                       "日语维持 12+句读 / 90 字")
        XCTAssertTrue(TurnManager.hasSpeakableOpening("这是一句完整的话。", language: .chinese))
        XCTAssertFalse(TurnManager.hasSpeakableOpening("还不够", language: .chinese))
        XCTAssertFalse(TurnManager.hasSpeakableOpening(String(repeating: "我", count: 23), language: .chinese))
    }

    /// 中文寒暄不许触发真回合（取消在途生成 + 烧计费调用 + 污染 history）。
    @MainActor
    func testChineseBackchannelsAreNotMeaningfulQuestions() {
        let tm = makeTurnManager(.chinese)
        XCTAssertFalse(tm.isMeaningfulQuestion("好的，我明白了。"))
        XCTAssertFalse(tm.isMeaningfulQuestion("谢谢您的回答。"))
        XCTAssertFalse(tm.isMeaningfulQuestion("那我们开始吧。"))
        XCTAssertTrue(tm.isMeaningfulQuestion("请介绍一下你自己。"))
        // 日语表目原样有效。
        XCTAssertFalse(tm.isMeaningfulQuestion("よろしくお願いします。"))
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

    /// 假名护栏：为日语面试写的事实（值/标签含かな）在中文面试里不即答——
    /// 中日混排句命中即定稿、没有生成兜底，宁可交给 LLM 用事实以中文重述。
    func testChineseQuickAnswerRefusesKanaFacts() {
        let facts = store("希望年収: 御社の規定に従います")
        XCTAssertNil(FactQuickAnswer.answer(for: "您的期望薪资是多少？", facts: facts,
                                            language: .chinese))
        // 同一条事实在日语面试照常即答。
        XCTAssertEqual(FactQuickAnswer.answer(for: "年収のご希望は？", facts: facts,
                                              language: .japanese),
                       "御社の規定に従います")
    }

    // MARK: - UI 文案跟随面试语言

    func testSttStringsFollowInterviewLanguage() {
        Settings.interviewLanguage = .chinese
        XCTAssertTrue(AppStrings(language: .zh).sttLocalUnavailable.contains("本地中文识别不可用"))
        Settings.interviewLanguage = .japanese
        XCTAssertTrue(AppStrings(language: .zh).sttLocalUnavailable.contains("本地日语识别不可用"))
    }
}
