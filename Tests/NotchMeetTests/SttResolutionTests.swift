import XCTest
@testable import notchmeet

final class SttResolutionTests: XCTestCase {
    func testApplePrefAlwaysApple() {
        XCTAssertEqual(Settings.resolveStt(pref: .apple, inChina: false, hasDeepgramKey: true), .apple)
    }
    func testAutoInChinaPicksApple() {
        XCTAssertEqual(Settings.resolveStt(pref: .auto, inChina: true, hasDeepgramKey: true), .apple)
    }
    func testAutoOutsideChinaWithKeyPicksDeepgram() {
        XCTAssertEqual(Settings.resolveStt(pref: .auto, inChina: false, hasDeepgramKey: true), .deepgram)
    }
    func testAutoOutsideChinaNoKeyPicksMock() {
        XCTAssertEqual(Settings.resolveStt(pref: .auto, inChina: false, hasDeepgramKey: false), .mock)
    }
    func testDeepgramPrefNoKeyFallsBackToMock() {
        XCTAssertEqual(Settings.resolveStt(pref: .deepgram, inChina: true, hasDeepgramKey: false), .mock)
    }

    func testSttEnginePrefRoundTripsThroughDefaults() {
        let prev = Settings.sttEngine
        defer { Settings.sttEngine = prev }
        Settings.sttEngine = .apple
        XCTAssertEqual(Settings.sttEngine, .apple)
    }
}
