import XCTest
@testable import notchmeet

final class MakeSttTests: XCTestCase {
    func testApplePrefReturnsAppleClient() {
        let prev = Settings.sttEngine
        defer { Settings.sttEngine = prev }
        Settings.sttEngine = .apple
        XCTAssertTrue(ProviderRegistry.makeStt() is AppleSpeechSttClient)
    }
}
