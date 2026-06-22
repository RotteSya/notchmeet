import XCTest
@testable import notchmeet

/// Guards the privacy-honesty fix. The disclosures must name the real recipients of the
/// user's data, and the two original false claims — "only the interviewer's voice" and
/// "data only stays on device" — must stay gone.
final class PrivacyDisclosureTests: XCTestCase {

    func testConsentBodyNamesEveryRecipientOfData() {
        for lang in [UILanguage.zh, .ja] {
            let body = AppStrings(language: lang).consentBody(llm: "Gemini", sendsContext: true)
            XCTAssertTrue(body.contains("Deepgram"), "consent must name Deepgram (\(lang))")
            XCTAssertTrue(body.contains("Gemini"), "consent must name the active LLM (\(lang))")
        }
    }

    func testConsentBodyReflectsContextOptOut() {
        let s = AppStrings(language: .zh)
        let on = s.consentBody(llm: "Claude", sendsContext: true)
        let off = s.consentBody(llm: "Claude", sendsContext: false)
        XCTAssertTrue(on.contains("简历") || on.contains("原稿"))
        XCTAssertNotEqual(on, off, "the disclosure must differ when context-sending is off")
    }

    func testOnboardingPrivacyCopyDropsTheFalseLocalOnlyClaim() {
        // The lie was that *data* stays on device; saying only the API key is local is fine.
        XCTAssertFalse(OBStrings.zh.privacy.contains("数据仅保存在本机"),
                       "the false 'data only stays on device' claim must be gone")
        XCTAssertTrue(OBStrings.zh.privacy.contains("Deepgram"))
        XCTAssertFalse(OBStrings.ja.privacy.contains("データは端末内に保存されます"),
                       "the false JA 'data stored on device' claim must be gone")
        XCTAssertTrue(OBStrings.ja.privacy.contains("Deepgram"))
    }

    func testOnboardingAudioCopyNoLongerClaimsOnlyInterviewer() {
        XCTAssertTrue(OBStrings.zh.p2.contains("通话 App"))
        XCTAssertFalse(OBStrings.zh.p2.contains("仅获取从扬声器或耳机播放的面试官声音"))
        XCTAssertTrue(OBStrings.ja.p2.contains("通話アプリ"))
    }

    func testAudioTargetAllowlistCoversCommonCallApps() {
        guard #available(macOS 14.4, *) else { return }
        XCTAssertTrue(AudioTargetResolver.nativeCallApps.contains("us.zoom.xos"))
        XCTAssertFalse(AudioTargetResolver.browserApps.isEmpty)
        XCTAssertEqual(AudioTargetResolver.knownCallApps.count,
                       AudioTargetResolver.nativeCallApps.count + AudioTargetResolver.browserApps.count)
    }
}
