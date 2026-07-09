import XCTest
@testable import notchmeet

/// 域内 LLM 端点（DeepSeek/Qwen）必须绕过系统代理直连：国内用户为开 Google Meet 常挂**全局模式**
/// 的梯子，会把本可直连的域内请求也带出境，握手/首 token 直接破 3s 预算。`LLMHTTP.directSession`
/// 显式忽略系统代理；境外端点（Gemini/Claude）仍走 `.shared`（用户正是靠系统代理才能访问它们）。
final class LLMHTTPProxyBypassTests: XCTestCase {
    /// 直连 session 必须**显式**关掉代理：空的 connectionProxyDictionary = 不使用任何代理。
    /// 注意 nil ≠ 空字典——nil 表示"沿用系统代理"，恰恰是这里要避免的行为。
    func testDirectSessionIgnoresSystemProxy() {
        let proxy = LLMHTTP.directSession.configuration.connectionProxyDictionary
        XCTAssertNotNil(proxy, "directSession 必须显式设置代理字典；nil 会沿用系统代理/梯子")
        XCTAssertEqual(proxy?.count, 0, "代理字典必须为空 = 直连，不经系统代理/梯子出境")
    }

    /// 直连 session 必须是独立实例，绝不能等于/覆盖 `.shared`——否则会误伤只能靠代理访问的
    /// 境外端点（Gemini/Claude）。
    func testDirectSessionIsSeparateFromShared() {
        XCTAssertFalse(LLMHTTP.directSession === URLSession.shared,
                       "directSession 不能是 .shared：境外端点仍需走系统代理")
    }
}
