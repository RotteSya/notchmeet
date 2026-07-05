import XCTest
@testable import notchmeet

final class AppleSpeechSttClientTests: XCTestCase {
    func testNotConnectedBeforeStart() {
        let c = AppleSpeechSttClient()
        XCTAssertFalse(c.isConnected)
    }

    func testWriteBeforeStartIsNoopAndDoesNotCrash() {
        let c = AppleSpeechSttClient()
        c.write([Int16](repeating: 0, count: 160).withUnsafeBufferPointer { Data(buffer: $0) })
        XCTAssertFalse(c.isConnected)
    }
}
