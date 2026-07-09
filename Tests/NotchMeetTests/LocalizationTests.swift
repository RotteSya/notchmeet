import XCTest
@testable import notchmeet

final class LocalizationTests: XCTestCase {
    func testLegacyLanguagePreferenceMigratesAndRemainsMirrored() throws {
        let suite = "notchmeet.localization.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set("ja", forKey: "nm_lang")
        let store = AppLanguageStore(defaults: defaults)

        XCTAssertEqual(store.language, .ja)
        store.language = .zh
        XCTAssertEqual(defaults.string(forKey: "nm_ui_language"), "zh")
        XCTAssertEqual(defaults.string(forKey: "nm_lang"), "zh")
    }

    func testChromeChangesLanguageWhileInterviewLanguageRemainsJapanese() {
        let zh = AppStrings(language: .zh)
        let ja = AppStrings(language: .ja)

        XCTAssertEqual(zh.notchTitle, "面试提词器")
        XCTAssertEqual(ja.notchTitle, "面接プロンプター")
        XCTAssertEqual(zh.runtimeMessage(.thinking), "思考中…")
        XCTAssertEqual(ja.runtimeMessage(.thinking), "考え中…")
        XCTAssertEqual(Settings.interviewLanguage.deepgramCode, "ja")
    }

    func testJapaneseInterviewPromptDoesNotFollowChromeLanguage() {
        let prompt = Prompts.system(context: "")

        XCTAssertTrue(prompt.contains("日本語のみで出力する"))
        XCTAssertTrue(prompt.contains("文系総合職"))
    }

    func testPreviouslyMixedMenuCopyIsLocalized() {
        XCTAssertEqual(AppStrings(language: .zh).buildAnswerBank, "预生成回答")
        XCTAssertEqual(AppStrings(language: .ja).buildAnswerBank, "回答を事前生成")
    }
}
