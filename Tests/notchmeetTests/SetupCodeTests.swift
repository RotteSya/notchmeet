import XCTest
@testable import notchmeet

final class SetupCodeTests: XCTestCase {
    /// base64url, no padding — matches `scripts/mint-code.sh` (base64 | tr '+/' '-_' | tr -d '=').
    private func code(_ json: String) -> String {
        let b64 = Data(json.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return SetupCode.prefix + b64
    }

    func testDecodesDeepgramAndLLMKeys() {
        let keys = SetupCode.decode(code(#"{"DEEPGRAM_API_KEY":"dg_abc","GEMINI_API_KEY":"gm_xyz"}"#))
        XCTAssertEqual(keys?["DEEPGRAM_API_KEY"], "dg_abc")
        XCTAssertEqual(keys?["GEMINI_API_KEY"], "gm_xyz")
        XCTAssertEqual(keys?.count, 2)
    }

    func testToleratesSurroundingWhitespace() {
        let raw = "  " + code(#"{"DEEPGRAM_API_KEY":"x"}"#) + "\n"
        XCTAssertEqual(SetupCode.decode(raw)?["DEEPGRAM_API_KEY"], "x")
    }

    func testRejectsRawApiKey() {
        // A normal pasted key must fall through to the per-field path, not be eaten as a code.
        XCTAssertNil(SetupCode.decode("3a1b2c9d0e8f7a6b5c4d3e2f1a0b9c8d7e6f5a4b"))
        XCTAssertNil(SetupCode.decode("AIzaSyD-EXAMPLE_gemini_key_value"))
    }

    func testRejectsPrefixWithGarbage() {
        XCTAssertNil(SetupCode.decode("nmk1.@@@not-base64@@@"))
    }

    func testRejectsEmptyJSONObject() {
        XCTAssertNil(SetupCode.decode(code("{}")))
    }
}
