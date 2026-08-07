import XCTest
@testable import notchmeet

/// 审计 R4/R5 的回归锁：转写断连必须可见，重连成功绝不能抹掉正在念的答案。
final class SttOutageUITests: XCTestCase {

    // MARK: R4 — 折叠态宝石

    /// 重连中宝石必须换成 .error（琥珀「!」）——折叠态唯一的可视元素就是它。
    func testMarkShowsErrorWhileReconnecting() {
        XCTAssertEqual(NotchPresentation.markStatus(status: .listening, message: .sttReconnecting),
                       .error)
        XCTAssertEqual(NotchPresentation.markStatus(status: .presenting, message: .sttReconnecting),
                       .error)
    }

    /// 非重连消息一律透传真实 status，不产生副作用。
    func testMarkPassesThroughOtherwise() {
        XCTAssertEqual(NotchPresentation.markStatus(status: .listening, message: .listening),
                       .listening)
        XCTAssertEqual(NotchPresentation.markStatus(status: .presenting, message: .completed),
                       .presenting)
    }

    // MARK: R5 — 断连快照 / 重连还原

    /// 核心案例：展示答案时断连 → 重连成功后还原到展示态，答案不清。
    /// 旧实现此处走 enterListening()，用户嘴巴念到一半答案凭空消失。
    func testReconnectRestoresPresentingSnapshot() {
        var st = SttOutageUIState()
        st.noteDisconnected(currentMessage: .completed, currentStatus: .presenting)
        let restore = st.noteReconnected(currentMessage: .sttReconnecting)
        XCTAssertEqual(restore?.message, .completed)
        XCTAssertEqual(restore?.status, .presenting)
    }

    /// 重连失败的反复 disconnected 不得把快照覆盖成 .sttReconnecting 自己。
    func testRepeatedDisconnectKeepsOriginalSnapshot() {
        var st = SttOutageUIState()
        st.noteDisconnected(currentMessage: .completed, currentStatus: .presenting)
        // 期间 UI 已显示 .sttReconnecting，重连失败再次进入 disconnected：
        st.noteDisconnected(currentMessage: .sttReconnecting, currentStatus: .presenting)
        let restore = st.noteReconnected(currentMessage: .sttReconnecting)
        XCTAssertEqual(restore?.message, .completed, "快照必须还是断连前的常态")
    }

    /// 断连期间回合已推进（message 被 .suggesting 等盖掉）→ 重连时不得碰 UI。
    func testReconnectDoesNothingWhenTurnMovedOn() {
        var st = SttOutageUIState()
        st.noteDisconnected(currentMessage: .listening, currentStatus: .listening)
        XCTAssertNil(st.noteReconnected(currentMessage: .suggesting),
                     "正在发生的回合永远比「恢复旧状态」优先")
    }

    /// 快照是一次性的：还原之后再次断连/重连，拿到的是新一轮的快照。
    func testSnapshotIsConsumedOnReconnect() {
        var st = SttOutageUIState()
        st.noteDisconnected(currentMessage: .completed, currentStatus: .presenting)
        _ = st.noteReconnected(currentMessage: .sttReconnecting)
        st.noteDisconnected(currentMessage: .listening, currentStatus: .listening)
        let restore = st.noteReconnected(currentMessage: .sttReconnecting)
        XCTAssertEqual(restore?.message, .listening)
        XCTAssertEqual(restore?.status, .listening)
    }
}
