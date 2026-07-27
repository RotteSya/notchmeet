import XCTest
@testable import notchmeet

/// STT 连接可靠性的回归锁。
///
/// 对应线上缺陷：Deepgram 客户端状态跨三条线程裸访问、stop→start 竞态可产生双 socket
/// 双路转录、半开连接无接收侧看门狗（中国区换节点后整段面试静默蒸发）、永久性故障
/// （Key 撤销/欠费）被当瞬断无限重连且被 AppController 的错误过滤器挡在 UI 之外。
final class SttReliabilityTests: XCTestCase {

    // MARK: - 永久故障必须可见

    /// `.streamUnavailable` 必须是 SttError —— AppController 的 onError 用
    /// `err is SttError` 决定是否上屏，不是这个类型就会被静默吞掉。
    func testStreamUnavailableIsSurfacedAsSttError() {
        let err: Error = SttError.streamUnavailable(detail: "401 Unauthorized")
        XCTAssertTrue(err is SttError, "永久故障必须能通过 AppController 的 SttError 过滤器")
    }

    /// 错误文案必须包含服务端给出的具体原因，用户才知道该查什么。
    func testStreamUnavailableCarriesActionableDetail() {
        let detail = "401 Unauthorized"
        let message = SttError.streamUnavailable(detail: detail).errorDescription ?? ""
        XCTAssertTrue(message.contains(detail), "应保留具体原因，实际: \(message)")
        XCTAssertFalse(message.isEmpty)
    }

    /// 重连上限必须是有限值——无限重连就是「整场面试盯着聆听中」。
    func testReconnectHasAFiniteCeiling() {
        XCTAssertGreaterThan(DeepgramSttClient.maxConsecutiveFailures, 0)
        XCTAssertLessThanOrEqual(DeepgramSttClient.maxConsecutiveFailures, 10,
                                 "上限过高等于没有上限：面试场景下用户等不了那么久")
    }

    /// 看门狗超时必须短于人类对「它是不是坏了」的忍耐窗口，且长于正常静默间隙。
    func testWatchdogTimeoutIsWithinAUsableWindow() {
        let seconds = Double(DeepgramSttClient.serverSilenceTimeoutNs) / 1e9
        XCTAssertGreaterThanOrEqual(seconds, 3, "太短会在正常停顿时误重连")
        XCTAssertLessThanOrEqual(seconds, 10, "太长则半开连接会吞掉整段提问")
    }

    // MARK: - 断句判定（Deepgram 侧 final 的触发条件之一）

    func testEndsSentenceRecognizesJapaneseAndASCIITerminators() {
        XCTAssertTrue(DeepgramSttClient.endsSentence("志望動機を教えてください。"))
        XCTAssertTrue(DeepgramSttClient.endsSentence("そうですか？"))
        XCTAssertTrue(DeepgramSttClient.endsSentence("なるほど！"))
        XCTAssertTrue(DeepgramSttClient.endsSentence("Really?"))
        XCTAssertTrue(DeepgramSttClient.endsSentence("Yes!"))
        // 尾随空白不应影响判定（Deepgram 常带尾空格）。
        XCTAssertTrue(DeepgramSttClient.endsSentence("お願いします。   "))
    }

    func testEndsSentenceRejectsMidUtteranceText() {
        XCTAssertFalse(DeepgramSttClient.endsSentence("学生時代に力を"))
        XCTAssertFalse(DeepgramSttClient.endsSentence("えーと"))
        XCTAssertFalse(DeepgramSttClient.endsSentence(""))
        XCTAssertFalse(DeepgramSttClient.endsSentence("   "))
    }

    // MARK: - 生命周期不崩

    /// stop→start 快速切换是旧实现产生双 socket 的路径。现在全部状态收在私有串行
    /// 队列上并用代际令牌隔离；这里至少保证反复切换不崩溃、不死锁。
    func testRapidStartStopCyclesAreSafe() throws {
        let client = DeepgramSttClient(apiKey: "test-key-not-used", language: "ja")
        for _ in 0..<20 {
            try client.start()
            client.stop()
        }
        // 队列排空后状态应回到未连接。
        let drained = expectation(description: "queue drained")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { drained.fulfill() }
        wait(for: [drained], timeout: 2)
        XCTAssertFalse(client.isConnected)
    }

    /// 未连接时写音频必须是安全的 no-op（音频线程每 ~20ms 调一次）。
    func testWriteWhileDisconnectedIsANoOp() {
        let client = DeepgramSttClient(apiKey: "test-key-not-used", language: "ja")
        XCTAssertFalse(client.isConnected)
        client.write(Data(repeating: 0, count: 640))   // 不应崩溃
    }
}
