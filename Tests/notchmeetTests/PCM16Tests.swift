import XCTest
import AVFoundation
@testable import notchmeet

final class PCM16Tests: XCTestCase {
    private func data(_ samples: [Int16]) -> Data {
        samples.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    func testFrameLengthMatchesSampleCount() {
        let buf = PCM16.buffer(from: data(Array(repeating: 1000, count: 320)))  // 20ms @16k
        XCTAssertNotNil(buf)
        XCTAssertEqual(buf?.frameLength, 320)
        XCTAssertEqual(buf?.format.sampleRate, 16000)
        XCTAssertEqual(buf?.format.channelCount, 1)
    }

    func testEmptyDataReturnsNil() {
        XCTAssertNil(PCM16.buffer(from: Data()))
    }

    func testSamplesCopiedIntoBuffer() {
        let buf = PCM16.buffer(from: data([0, 32767, -32768, 5]))
        XCTAssertEqual(buf?.int16ChannelData?.pointee[1], 32767)
        XCTAssertEqual(buf?.int16ChannelData?.pointee[2], -32768)
    }
}
