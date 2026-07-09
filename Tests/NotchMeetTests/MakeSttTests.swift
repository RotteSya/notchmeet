import XCTest
@testable import notchmeet

final class MakeSttTests: XCTestCase {
    func testApplePrefReturnsAppleClient() {
        let prev = Settings.sttEngine
        defer { Settings.sttEngine = prev }
        Settings.sttEngine = .apple
        XCTAssertTrue(ProviderRegistry.makeStt() is AppleSpeechSttClient)
    }

    func testSttResolutionApplePrefIsLiveEngine() {
        let prev = Settings.sttEngine
        defer { Settings.sttEngine = prev }
        Settings.sttEngine = .apple
        // The .auto launch gate arms the live pipeline iff resolution != .mock.
        // Apple pref must resolve to a live (non-mock) engine regardless of key/region.
        XCTAssertEqual(ProviderRegistry.sttResolution(), .apple)
        XCTAssertNotEqual(ProviderRegistry.sttResolution(), .mock)
    }
}
