import XCTest
@testable import notchmeet

/// 审计 R6 的回归锁：无 LLM Key 的**真实会话**必须显式报错，绝不吐以假乱真的模板。
final class UnconfiguredGeneratorTests: XCTestCase {

    /// 行为契约：一个字不吐、立即抛 missingKey（刘海据此显示可行动的错误文案）。
    func testThrowsMissingKeyWithoutEmittingAnything() async {
        let gen = UnconfiguredAnswerGenerator()
        var text = ""
        do {
            try await gen.generate(GenRequest(question: "強みは？", context: "", history: ""),
                                   epoch: 1) { text += $0 }
            XCTFail("必须抛错")
        } catch {
            guard case LLMError.missingKey = error else {
                return XCTFail("必须是 missingKey，实际 \(error)")
            }
        }
        XCTAssertEqual(text, "", "不得吐出任何以假乱真的内容")
    }

    /// 源码扫描：makeGenerator 的无 Key 兜底不得再退回 MockAnswerGenerator。
    /// mock 的流利假答案在刘海上与真答案毫无区别（.auto 国内路径 STT 不需要 Key，
    /// 管线照常 arm，最容易撞上）；mock 只允许出现在显式的 demo/QA 管线。
    func testProviderRegistryNeverFallsBackToMock() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/NotchMeetTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/NotchMeet/LLM/ProviderRegistry.swift"),
            encoding: .utf8)
        XCTAssertFalse(source.contains("return MockAnswerGenerator("),
                       "ProviderRegistry 不得把 mock 假答案交给真实会话（审计 R6）")
        XCTAssertTrue(source.contains("UnconfiguredAnswerGenerator("),
                      "无 Key 兜底必须是显式报错的 UnconfiguredAnswerGenerator")
    }
}
