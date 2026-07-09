import XCTest
@testable import notchmeet

final class SttStringsTests: XCTestCase {
    func testEngineOptionLabelsLocalized() {
        XCTAssertEqual(AppStrings(language: .zh).sttEngineApple, "Apple 本地（离线）")
        XCTAssertEqual(AppStrings(language: .ja).sttEngineApple, "Apple（オンデバイス）")
        XCTAssertEqual(AppStrings(language: .zh).sttEngineAuto, "自动")
    }
    func testErrorStringsLocalized() {
        XCTAssertTrue(AppStrings(language: .zh).sttLocalUnavailable.contains("本地日语识别不可用"))
        XCTAssertTrue(AppStrings(language: .ja).sttNotAuthorized.contains("音声認識"))
    }
    func testSttErrorRuntimeMessageLocalized() {
        XCTAssertEqual(AppStrings(language: .zh).runtimeMessage(.sttError), "语音识别不可用")
        XCTAssertEqual(AppStrings(language: .ja).runtimeMessage(.sttError), "音声認識が利用できません")
    }
}
