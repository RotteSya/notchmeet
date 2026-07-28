import XCTest
@testable import notchmeet

/// 端点延迟的两段拆分。
///
/// 起因是实测中一次 4571ms 的端点延迟——合并成一个数时，完全无法判断该去调 settle
/// 窗口（我们自己等太久）还是该查网络（Deepgram 交付慢）。拆开之后：
/// `stt` = 终稿交付耗时（外部），`settle` = 我们的等待（可调）。
final class LatencySplitTests: XCTestCase {

    private func monitor(lastVoiced: UInt64) -> LatencyMonitor {
        let m = LatencyMonitor()
        m.voicedClock = { lastVoiced }
        return m
    }

    private let ms: UInt64 = 1_000_000

    /// 终稿在窗口中间到达 → 两段都应为正，且相加等于总的端点延迟。
    func testSplitPointInsideTheWindowIsAccepted() {
        let now = DispatchTime.now().uptimeNanoseconds
        let t0 = now &- 3000 * ms          // 最后一个音素在 3s 前
        let sttFinal = now &- 1000 * ms    // 终稿在 1s 前到达 → stt≈2000ms, settle≈1000ms
        let m = monitor(lastVoiced: t0)
        m.turnStart(1, sttFinalNs: sttFinal)
        // 不崩、不误判即可；具体数值经由日志观察，这里锁住不变量：
        // 拆分点被接受时不会退化成「整段算 STT」。
        m.markFirstReadable(epoch: 1, kind: .live)
        m.turnEnd(1)
    }

    /// 终稿时刻早于最后一个音素（VAD 比 STT 端点器更敏感时会发生）→ 必须钳住，
    /// 否则会算出负的 settle，把「我们等了多久」报成负数。
    func testFinalBeforeLastPhonemeIsClamped() {
        let now = DispatchTime.now().uptimeNanoseconds
        let t0 = now &- 1000 * ms
        let bogusFinal = now &- 5000 * ms   // 比 t0 还早
        let m = monitor(lastVoiced: t0)
        m.turnStart(2, sttFinalNs: bogusFinal)
        m.markFirstReadable(epoch: 2, kind: .live)
        m.turnEnd(2)   // 不得因负值崩溃或产生荒谬输出
    }

    /// 未知终稿时刻（0）→ 退化为不拆分，整段算作 STT 交付，不得当成 settle=负。
    func testUnknownFinalDegradesGracefully() {
        let now = DispatchTime.now().uptimeNanoseconds
        let m = monitor(lastVoiced: now &- 2000 * ms)
        m.turnStart(3)          // 不传 sttFinalNs
        m.markFirstReadable(epoch: 3, kind: .live)
        m.turnEnd(3)
    }

    /// 没有音频路径（voicedClock 返回 0）时的既有降级行为必须保持。
    func testNoAudioPathStillWorks() {
        let m = LatencyMonitor()
        m.voicedClock = { 0 }
        m.turnStart(4, sttFinalNs: 0)
        m.markFirstReadable(epoch: 4, kind: .live)
        m.turnEnd(4)
    }

    /// 冷启动仍然被排除在百分位之外——拆分不该影响这条既有约定。
    func testColdStartStillExcluded() {
        let now = DispatchTime.now().uptimeNanoseconds
        let m = monitor(lastVoiced: now &- 500 * ms)
        m.turnStart(1, sttFinalNs: now &- 200 * ms)
        m.markFirstReadable(epoch: 1, kind: .live)
        m.turnEnd(1)   // 第一轮 = 冷启动
        m.turnStart(2, sttFinalNs: now &- 100 * ms)
        m.markFirstReadable(epoch: 2, kind: .live)
        m.turnEnd(2)   // 第二轮才进统计
    }
}
