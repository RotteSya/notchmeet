import XCTest
@testable import notchmeet

/// 国内网络 + 只有被墙端点 Key（Gemini/Claude）时，面试前自检与 Onboarding 就绪
/// 判定必须显性警告——否则用户会带着只能超时的配置进入真实面试。
final class LLMChinaWarningTests: XCTestCase {
    // MARK: - 判定逻辑（纯函数）

    func testBlockedEndpointsWarnOnlyInChina() {
        XCTAssertTrue(Settings.llmBlockedInChina(.gemini, inChina: true))
        XCTAssertTrue(Settings.llmBlockedInChina(.claude, inChina: true))
        XCTAssertFalse(Settings.llmBlockedInChina(.gemini, inChina: false),
                       "境外 Gemini/Claude 可直连，不该警告")
        XCTAssertFalse(Settings.llmBlockedInChina(.claude, inChina: false))
    }

    func testDomesticOrMissingLLMNeverWarns() {
        XCTAssertFalse(Settings.llmBlockedInChina(.qwen, inChina: true))
        XCTAssertFalse(Settings.llmBlockedInChina(.deepseek, inChina: true))
        XCTAssertFalse(Settings.llmBlockedInChina(.none, inChina: true),
                       "没配 Key 走「未设置」路径，不该叠加直连警告")
    }

    /// 与 resolveLLM 串联：国内只有 Gemini key → 警告；补千问 key 后解析自动切到
    /// .qwen → 警告消失（无需删旧 key）。
    func testChinaOnlyGlobalKeyWarnsAndDomesticKeyClearsIt() {
        let onlyGemini = Settings.resolveLLM(hasGemini: true, hasClaude: false,
                                             hasDeepSeek: false, hasQwen: false, inChina: true)
        XCTAssertTrue(Settings.llmBlockedInChina(onlyGemini, inChina: true))

        let withQwen = Settings.resolveLLM(hasGemini: true, hasClaude: false,
                                           hasDeepSeek: false, hasQwen: true, inChina: true)
        XCTAssertFalse(Settings.llmBlockedInChina(withQwen, inChina: true))
    }

    // MARK: - 自检快照携带警告位

    func testHealthDefaultsToNoChinaWarning() {
        XCTAssertFalse(ControlPanel.Health.empty.llmChinaBlocked)
    }

    // MARK: - 文案（zh/ja 双语，且都点名可直连的替代服务）

    func testControlPanelWarningCopyIsBilingualAndActionable() {
        let zh = AppStrings(language: .zh).llmChinaBlockedWarning
        let ja = AppStrings(language: .ja).llmChinaBlockedWarning
        XCTAssertTrue(zh.contains("无法直连"))
        XCTAssertTrue(zh.contains("通义千问") && zh.contains("DeepSeek"))
        XCTAssertTrue(ja.contains("接続できません"))
        XCTAssertTrue(ja.contains("通義千問") && ja.contains("DeepSeek"))
    }

    func testOnboardingWarningCopyIsBilingualAndActionable() {
        XCTAssertTrue(OBStrings.zh.llmChinaFoot.contains("通义千问"))
        XCTAssertTrue(OBStrings.zh.llmChinaFoot.contains("DeepSeek"))
        XCTAssertTrue(OBStrings.ja.llmChinaFoot.contains("通義千問"))
        XCTAssertTrue(OBStrings.ja.llmChinaFoot.contains("DeepSeek"))
        XCTAssertFalse(OBStrings.zh.sumLLMBlocked.isEmpty)
        XCTAssertFalse(OBStrings.ja.sumLLMBlocked.isEmpty)
    }
}
