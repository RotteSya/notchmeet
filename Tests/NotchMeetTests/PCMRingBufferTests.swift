import XCTest
@testable import notchmeet

/// 环形缓冲的正确性锁。
///
/// 这段代码的错误是**静默**的：off-by-one 不会崩溃，只会让音频里混进一小段错位样本，
/// 表现为 STT 偶发识别错误——几乎不可能从现场反推。所以这里连绕回、溢出、并发都测。
final class PCMRingBufferTests: XCTestCase {

    private func makeRing(capacitySamples: Int) -> PCMRingBuffer {
        // capacity = sampleRate * channels * seconds，用 channels=1、seconds=1 直接给定。
        PCMRingBuffer(sampleRate: Double(capacitySamples), channels: 1, seconds: 1)
    }

    private func write(_ ring: PCMRingBuffer, _ values: [Float]) {
        values.withUnsafeBufferPointer { buf in
            if let p = buf.baseAddress { ring.write(p, count: values.count) }
        }
    }

    private func read(_ ring: PCMRingBuffer, max: Int) -> [Float] {
        var out = [Float](repeating: 0, count: max)
        let got = out.withUnsafeMutableBufferPointer { buf -> Int in
            guard let p = buf.baseAddress else { return 0 }
            return ring.read(into: p, max: max)
        }
        return Array(out.prefix(got))
    }

    // MARK: - 基本往返

    func testRoundTripPreservesOrderAndValues() {
        let ring = makeRing(capacitySamples: 8192)
        let input: [Float] = (0..<100).map { Float($0) * 0.01 }
        write(ring, input)
        XCTAssertEqual(read(ring, max: 100), input)
    }

    func testReadOnEmptyReturnsNothing() {
        let ring = makeRing(capacitySamples: 8192)
        XCTAssertEqual(read(ring, max: 64).count, 0)
    }

    func testPartialReadLeavesRemainder() {
        let ring = makeRing(capacitySamples: 8192)
        let input: [Float] = (0..<50).map { Float($0) }
        write(ring, input)
        XCTAssertEqual(read(ring, max: 20), Array(input.prefix(20)))
        XCTAssertEqual(read(ring, max: 100), Array(input.suffix(30)))
    }

    // MARK: - 绕回（最容易写错的地方）

    /// 反复写读远超容量的总量，验证绕回后数据仍逐样本正确。
    func testWrapAroundPreservesEverySample() {
        let capacity = 4096
        let ring = makeRing(capacitySamples: capacity)
        let chunk = 300                      // 与容量不整除，强制在各种偏移上绕回
        var expected: Float = 0
        for _ in 0..<200 {
            let input = (0..<chunk).map { Float(expected) + Float($0) }
            write(ring, input)
            let out = read(ring, max: chunk)
            XCTAssertEqual(out, input, "绕回后样本必须逐一致")
            expected += Float(chunk)
        }
    }

    /// 写入块跨越物理数组末尾时的两段拷贝路径。
    func testWriteSpanningTheEndOfStorage() {
        let capacity = 4096
        let ring = makeRing(capacitySamples: capacity)
        // 先把读写指针推到接近末尾。
        let filler = [Float](repeating: 1, count: capacity - 10)
        write(ring, filler)
        _ = read(ring, max: capacity - 10)
        // 现在写一块必然跨越边界。
        let input: [Float] = (0..<100).map { Float($0) + 1000 }
        write(ring, input)
        XCTAssertEqual(read(ring, max: 100), input)
    }

    // MARK: - 溢出（消费者跟不上）

    /// 缓冲满时必须丢弃新块并计数，绝不覆盖未读数据、绝不阻塞。
    func testOverflowDropsBlockAndCountsIt() {
        let capacity = 4096
        let ring = makeRing(capacitySamples: capacity)
        let good = [Float](repeating: 7, count: capacity - 1)
        write(ring, good)
        XCTAssertEqual(ring.takeOverflowCount(), 0)

        write(ring, [Float](repeating: 99, count: 64))   // 放不下 → 丢弃
        XCTAssertEqual(ring.takeOverflowCount(), 1)
        XCTAssertEqual(ring.takeOverflowCount(), 0, "取出后应清零")

        // 已有数据未被破坏。
        let out = read(ring, max: capacity)
        XCTAssertEqual(out.count, capacity - 1)
        XCTAssertTrue(out.allSatisfy { $0 == 7 }, "溢出不得覆盖未读数据")
    }

    /// 超过容量的单块直接拒绝，不做部分写入（部分写入 = 撕裂的音频）。
    func testOversizedWriteIsRejectedWholesale() {
        let ring = makeRing(capacitySamples: 4096)
        write(ring, [Float](repeating: 1, count: 5000))
        XCTAssertEqual(read(ring, max: 5000).count, 0, "超容量块不得部分写入")
    }

    // MARK: - 并发（真实使用形态：IO 线程写 / drain 队列读）

    /// 单生产者 + 单消费者并发跑，验证消费端拿到的是**连续递增**序列——
    /// 任何撕裂、重复或乱序都会破坏单调性。
    func testConcurrentProducerConsumerKeepsSequenceMonotonic() {
        let ring = PCMRingBuffer(sampleRate: 48000, channels: 1, seconds: 1)
        let totalChunks = 2000
        let chunkSize = 240
        let done = expectation(description: "producer finished")

        var received: [Float] = []
        received.reserveCapacity(totalChunks * chunkSize)
        let consumerDone = expectation(description: "consumer drained")

        DispatchQueue.global(qos: .userInitiated).async {
            var counter: Float = 0
            for _ in 0..<totalChunks {
                let chunk = (0..<chunkSize).map { _ -> Float in counter += 1; return counter }
                chunk.withUnsafeBufferPointer { buf in
                    if let p = buf.baseAddress { ring.write(p, count: chunkSize) }
                }
            }
            done.fulfill()
        }

        DispatchQueue.global(qos: .userInitiated).async {
            var scratch = [Float](repeating: 0, count: 4096)
            var idleRounds = 0
            while idleRounds < 200 {
                let got = scratch.withUnsafeMutableBufferPointer { buf -> Int in
                    guard let p = buf.baseAddress else { return 0 }
                    return ring.read(into: p, max: 4096)
                }
                if got == 0 { idleRounds += 1; usleep(500); continue }
                idleRounds = 0
                received.append(contentsOf: scratch.prefix(got))
            }
            consumerDone.fulfill()
        }

        wait(for: [done, consumerDone], timeout: 30)

        XCTAssertFalse(received.isEmpty, "消费者应当拿到数据")
        // 允许因溢出丢块（生产者故意跑得比消费者快），但拿到的必须严格递增：
        // 撕裂/重复/乱序都会在这里暴露。
        for i in 1..<received.count {
            XCTAssertGreaterThan(received[i], received[i - 1],
                                 "样本序列必须严格递增（位置 \(i)）")
        }
    }
}
