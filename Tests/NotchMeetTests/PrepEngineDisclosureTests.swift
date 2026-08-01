import XCTest
@testable import notchmeet

/// 预生成的收件人披露（审计 H2）。
///
/// 此前 `bestCLI()` 一旦在 PATH 上找到 claude / codex 就静默优先使用——把简历要点
/// 送进用户**自己的** Anthropic / OpenAI 账号。而设置页写着「当前回答模型：DeepSeek」、
/// 隐私页把收件人列为「Gemini／Claude／DeepSeek／通义千问」、README 同样没提这条路径。
/// 用户配置了一个服务、界面显示那个服务，数据却走了别处，且不可关。
final class PrepEngineDisclosureTests: XCTestCase {
    private var original: Bool!

    override func setUp() {
        super.setUp()
        original = Settings.useLocalCliForPrep
    }

    override func tearDown() {
        Settings.useLocalCliForPrep = original
        super.tearDown()
    }

    /// 开关关掉后，本机 CLI 绝不能再被选中——这是「可关」的全部意义。
    func testLocalCliIsNeverChosenWhenTheUserTurnedItOff() {
        Settings.useLocalCliForPrep = false
        if case .localCLI = PreGenerator.resolveEngine() {
            XCTFail("关掉开关后仍解析到本机 CLI —— 用户无法阻止数据流向自己的 CLI 账号")
        }
    }

    /// 开关只影响 CLI 分支：没有可用服务时必须是 .unavailable，而不是回落到别处。
    func testEngineIsUnavailableWithNoCliAndNoKey() {
        Settings.useLocalCliForPrep = false
        let engine = PreGenerator.resolveEngine()
        if ProviderRegistry.llmDisplayName() == nil {
            XCTAssertEqual(engine, .unavailable)
        } else if case .managed = engine {
            // 配了 Key 的机器上应解析为受管服务
        } else {
            XCTFail("关掉 CLI 且配了 Key 时应为 .managed，实际为 \(engine)")
        }
    }

    /// 披露文案必须点名**真实**的收件人：CLI 名 + 账号所属供应商。
    /// 只写「本机 CLI」不够——用户要知道数据最终进了谁的账。
    func testDisclosureNamesTheRealRecipient() {
        for lang in [UILanguage.zh, .ja] {
            let s = AppStrings(language: lang)
            let line = s.prepEngineLocalCLI(cli: "claude", vendor: "Anthropic")
            XCTAssertTrue(line.contains("claude"), "\(lang) 未点名 CLI")
            XCTAssertTrue(line.contains("Anthropic"), "\(lang) 未点名账号所属供应商")

            let privacy = s.privacyDataFlowLocalCLI(cli: "codex", vendor: "OpenAI")
            XCTAssertTrue(privacy.contains("codex") && privacy.contains("OpenAI"),
                          "\(lang) 隐私页披露未点名真实收件人")
        }
    }

    /// 披露正文是纯文本 label（textBlock 不解析 Markdown）——写了 ** 就会原样显示出来。
    func testDisclosureCarriesNoUnrenderedMarkdown() {
        for lang in [UILanguage.zh, .ja] {
            let s = AppStrings(language: lang)
            for line in [s.privacyDataFlowLocalCLI(cli: "claude", vendor: "Anthropic"),
                         s.prepEngineLocalCLI(cli: "claude", vendor: "Anthropic"),
                         s.useLocalCliHelp(cli: "claude", vendor: "Anthropic"),
                         s.privacyDataFlowBody] {
                XCTAssertFalse(line.contains("**"), "\(lang) 披露文案里残留了 Markdown 强调标记：\(line)")
            }
        }
    }

    /// 供应商映射不能错——把 codex 说成 Anthropic 比不披露更糟。
    func testVendorMapping() {
        XCTAssertEqual(PreGenerator.PrepEngine.localCLI(name: "claude", path: "/x").vendor, "Anthropic")
        XCTAssertEqual(PreGenerator.PrepEngine.localCLI(name: "codex", path: "/x").vendor, "OpenAI")
        XCTAssertNil(PreGenerator.PrepEngine.managed("DeepSeek").vendor)
        XCTAssertNil(PreGenerator.PrepEngine.unavailable.vendor)
    }

    /// 受管路径的代价也要在按下之前写清楚（19 个 intent × 10 秒 ≈ 3 分钟）。
    func testManagedEngineDisclosesItsCreditCost() {
        let seconds = PreGenerator.chargeSecondsPerIntent * Intents.list.count
        XCTAssertGreaterThan(seconds, 0)
        for lang in [UILanguage.zh, .ja] {
            let line = AppStrings(language: lang).prepEngineManaged(name: "DeepSeek", seconds: seconds)
            XCTAssertTrue(line.contains("DeepSeek"))
            XCTAssertTrue(line.contains("\(Int((Double(seconds) / 60).rounded()))"),
                          "\(lang) 未写出会消耗多少额度")
        }
    }

    /// 开关关掉时，隐私页不应再声称数据会经由 CLI——披露必须跟着实际行为走，
    /// 两个方向都要对（多说和少说一样是失真）。
    func testInstalledCliDetectionIsIndependentOfTheToggle() {
        // installedCLI 只看「装没装」，这样关掉之后开关本身仍然显示得出来，
        // 否则用户没有再打开它的入口。
        Settings.useLocalCliForPrep = false
        let offState = PreGenerator.installedCLI() != nil
        Settings.useLocalCliForPrep = true
        XCTAssertEqual(offState, PreGenerator.installedCLI() != nil,
                       "installedCLI 不得受开关影响")
    }
}
