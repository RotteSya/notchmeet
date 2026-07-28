import Foundation
import os

/// 单生产者（CoreAudio IO 线程）/ 单消费者（专用串行队列）的交织 Float32 环形缓冲。
///
/// 存在的理由：IO 回调是硬实时的。旧实现在回调里做 `AVAudioPCMBuffer` 堆分配、
/// `AVAudioConverter.convert`（内部还有自己的分配与锁）、`NSLog`，并且紧接着通过
/// `onPCM` 同步调用 `URLSessionWebSocketTask.send`，把整个 NSURLSession 状态机拖上
/// 实时线程。任一处卡顿就是 HAL overload 丢采集帧——表现为「面试官的问题缺了几个字
/// → STT 出残句 → 路由命中错答案」，是那类现场事故的物理成因之一。
///
/// 这里 IO 侧只做交织写入与索引发布：无堆分配、无 ObjC 派发、无日志、无系统调用。
/// 索引用 `OSAllocatedUnfairLock` 保护——临界区仅两条整数赋值，未竞争时是原子指令
/// 量级；比现状低几个数量级，且消费者持锁时间同样极短，不构成优先级反转风险。
final class PCMRingBuffer {
    private let capacity: Int                  // 以 float 采样点计
    private let storage: UnsafeMutablePointer<Float>
    private let indices = OSAllocatedUnfairLock(initialState: Indices())
    private let overflow = OSAllocatedUnfairLock(initialState: 0)

    private struct Indices {
        var write = 0
        var read = 0
    }

    /// - Parameter seconds: 缓冲时长上限。48kHz 立体声 1 秒 ≈ 96k float ≈ 384KB。
    init(sampleRate: Double, channels: Int, seconds: Double = 1.0) {
        capacity = max(4096, Int(sampleRate * Double(max(1, channels)) * seconds))
        storage = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
        storage.initialize(repeating: 0, count: capacity)
    }

    deinit {
        storage.deinitialize(count: capacity)
        storage.deallocate()
    }

    /// **实时线程调用**。写入交织 float 采样；缓冲满则丢弃本块——
    /// 宁可丢一块也绝不阻塞 IO 回调。
    func write(_ src: UnsafePointer<Float>, count: Int) {
        guard count > 0, count < capacity else { return }
        let (w, r) = indices.withLock { ($0.write, $0.read) }
        guard capacity - (w &- r) >= count else {
            overflow.withLock { $0 &+= 1 }
            return
        }
        let start = w % capacity
        let first = min(count, capacity - start)
        storage.advanced(by: start).update(from: src, count: first)
        if first < count {
            storage.update(from: src.advanced(by: first), count: count - first)
        }
        indices.withLock { $0.write = w &+ count }
    }

    /// **消费者线程调用**。取出至多 `max` 个采样，返回实际取出数量。
    func read(into dst: UnsafeMutablePointer<Float>, max maxCount: Int) -> Int {
        let (w, r) = indices.withLock { ($0.write, $0.read) }
        let available = Swift.min(w &- r, maxCount)
        guard available > 0 else { return 0 }
        let start = r % capacity
        let first = Swift.min(available, capacity - start)
        dst.update(from: storage.advanced(by: start), count: first)
        if first < available {
            dst.advanced(by: first).update(from: storage, count: available - first)
        }
        indices.withLock { $0.read = r &+ available }
        return available
    }

    /// 尚未被消费的采样数。消费者用它把时间戳往回推算——刚读出的那一块音频，
    /// 其末尾对应的采集时刻是「现在减去这些残留采样的时长」，而不是「现在」。
    var availableSamples: Int {
        indices.withLock { $0.write &- $0.read }
    }

    /// 取出并清零溢出计数（诊断日志用）。持续非零 = 消费者跟不上，需要调查。
    func takeOverflowCount() -> Int {
        overflow.withLock { let v = $0; $0 = 0; return v }
    }
}
