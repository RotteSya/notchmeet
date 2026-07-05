import XCTest
@testable import notchmeet

final class UtteranceEndpointerTests: XCTestCase {
    private func chunk(_ value: Int16, _ count: Int) -> Data {
        [Int16](repeating: value, count: count).withUnsafeBufferPointer { Data(buffer: $0) }
    }

    func testEndpointFiresAfterSilenceFollowingVoice() {
        var ep = UtteranceEndpointer(silenceThreshold: 0.01, silenceSamplesToEndpoint: 200)
        XCTAssertFalse(ep.feed(chunk(8000, 160)))   // voiced
        XCTAssertFalse(ep.feed(chunk(0, 100)))       // 100 silent < 200
        XCTAssertTrue(ep.feed(chunk(0, 150)))        // 累计 250 ≥ 200 → 端点
    }

    func testLeadingSilenceDoesNotFire() {
        var ep = UtteranceEndpointer(silenceThreshold: 0.01, silenceSamplesToEndpoint: 100)
        XCTAssertFalse(ep.feed(chunk(0, 500)))       // 从未见语音
    }

    func testFiresOnlyOncePerUtterance() {
        var ep = UtteranceEndpointer(silenceThreshold: 0.01, silenceSamplesToEndpoint: 100)
        _ = ep.feed(chunk(8000, 160))
        XCTAssertTrue(ep.feed(chunk(0, 200)))        // 触发一次
        XCTAssertFalse(ep.feed(chunk(0, 200)))       // 已复位、其后无语音 → 不再触发
    }

    func testVoiceResetsSilenceRun() {
        var ep = UtteranceEndpointer(silenceThreshold: 0.01, silenceSamplesToEndpoint: 200)
        _ = ep.feed(chunk(8000, 160))
        XCTAssertFalse(ep.feed(chunk(0, 150)))       // 150 silent
        XCTAssertFalse(ep.feed(chunk(8000, 32)))     // 语音打断 → 复位
        XCTAssertFalse(ep.feed(chunk(0, 150)))       // 又 150 < 200 → 不触发
    }
}
