import Foundation
import AVFoundation
import CoreAudio
import AudioToolbox
import os

/// Captures the OUTPUT audio of a SINGLE target app (the call app) via a Core Audio
/// process tap + private aggregate device (macOS 14.4+), converts to 16 kHz mono PCM16,
/// and emits it via `onPCM`. No BlackHole / virtual device.
///
/// `.callApp` mode resolves the target with `AudioTargetResolver` (only the call app's
/// audio is captured — never all system audio; that is the privacy promise the page makes).
/// `.probeGlobal` mode is used ONLY to trigger the macOS audio-capture permission prompt
/// during onboarding: it captures nothing (no `onPCM`) and is torn down immediately.
///
/// **线程契约**：IO 回调只把采样交织进 `PCMRingBuffer`（无分配、无锁竞争、无日志）；
/// 重采样、峰值扫描与 `onPCM` 全部在 `drainQueue` 上完成。因此 `onPCM` 的调用方
/// （STT 上传）不再运行在实时线程上——这是 §14.4 欠下的技术债，现已偿还。
@available(macOS 14.4, *)
final class CoreAudioTapCapture: NSObject, AudioCapture {
    /// What the tap listens to. `.callApp` = only the resolved call app; `.probeGlobal` =
    /// a throwaway global tap used solely to surface the TCC permission prompt.
    enum Target { case callApp, probeGlobal }

    var onPCM: ((Data) -> Void)?

    private let target: Target

    init(target: Target = .callApp) {
        self.target = target
        super.init()
    }

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var inputFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!

    func start() throws {
        // 1. Build the tap. `.callApp` taps ONLY the resolved call app(s); `.probeGlobal` is
        //    a throwaway used to trigger the permission prompt and never reaches `onPCM`.
        let desc: CATapDescription
        switch target {
        case .callApp:
            guard let resolution = AudioTargetResolver.resolve(), !resolution.ids.isEmpty else {
                throw AudioError.noCallApp
            }
            NSLog("[audio] capturing only: %@", resolution.label)
            desc = CATapDescription(stereoMixdownOfProcesses: resolution.ids)
        case .probeGlobal:
            desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        }
        desc.uuid = UUID()
        desc.muteBehavior = .unmuted

        var tap = AudioObjectID(kAudioObjectUnknown)
        let e1 = AudioHardwareCreateProcessTap(desc, &tap)
        guard e1 == noErr else { throw AudioError.tap(e1) }
        tapID = tap

        // 2. Private aggregate device that includes the tap.
        let aggDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "notchmeet-tap",
            kAudioAggregateDeviceUIDKey as String: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceIsStackedKey as String: false,
            kAudioAggregateDeviceTapAutoStartKey as String: true,
            kAudioAggregateDeviceTapListKey as String: [
                [
                    kAudioSubTapUIDKey as String: desc.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey as String: true,
                ],
            ],
        ]
        var agg = AudioObjectID(kAudioObjectUnknown)
        let e2 = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &agg)
        guard e2 == noErr else { throw AudioError.aggregate(e2) }
        aggregateID = agg

        // 3. Input stream format of the aggregate device.
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: 0)
        let e3 = AudioObjectGetPropertyData(aggregateID, &addr, 0, nil, &size, &asbd)
        guard e3 == noErr else { throw AudioError.format(e3) }
        guard let inFmt = AVAudioFormat(streamDescription: &asbd) else { throw AudioError.format(-1) }
        inputFormat = inFmt
        // 转换器在消费者队列上使用（AVAudioConverter 非线程安全，但只有 drain 碰它）。
        let interleavedIn = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                          sampleRate: inFmt.sampleRate,
                                          channels: inFmt.channelCount,
                                          interleaved: true) ?? inFmt
        converter = AVAudioConverter(from: interleavedIn, to: outputFormat)
        // 5. 先起消费者，再开 IO——保证第一批采样有人接。
        startDrain(inputFormat: inFmt)

        // 4. IO proc → ring buffer（实时线程到此为止）。
        var pid: AudioDeviceIOProcID?
        let e4 = AudioDeviceCreateIOProcIDWithBlock(&pid, aggregateID, nil) { [weak self] _, inInput, _, _, _ in
            self?.handle(inInput)
        }
        guard e4 == noErr, let pid else { throw AudioError.ioproc(e4) }
        procID = pid

        let e5 = AudioDeviceStart(aggregateID, pid)
        guard e5 == noErr else { throw AudioError.start(e5) }
        NSLog("[audio] tap started, input=%.0fHz/%dch", inFmt.sampleRate, Int(inFmt.channelCount))
    }

    func stop() {
        if let pid = procID {
            AudioDeviceStop(aggregateID, pid)
            AudioDeviceDestroyIOProcID(aggregateID, pid)
            procID = nil
        }
        // IO 已停 → 生产者不再写入，此时收消费者才不会丢尾包。
        stopDrain()
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
    }

    // MARK: - 实时线程 → 环形缓冲 → 消费者队列

    /// **实时线程**：只做交织与 memcpy。无堆分配、无锁竞争、无 ObjC 派发、无日志。
    private func handle(_ inData: UnsafePointer<AudioBufferList>) {
        guard let ring, let inFmt = inputFormat else { return }
        let src = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
        guard let first = src.first, let base = first.mData else { return }

        if src.count == 1 {
            // 已交织（或单声道）：整块写入。
            let count = Int(first.mDataByteSize) / MemoryLayout<Float>.size
            ring.write(base.assumingMemoryBound(to: Float.self), count: count)
            return
        }
        // 分离声道：边读边交织写入（纯算术 + 存储，仍然实时安全）。
        let framesPerChannel = Int(first.mDataByteSize) / MemoryLayout<Float>.size
        let channels = Swift.min(Int(inFmt.channelCount), src.count)
        guard channels > 0, framesPerChannel > 0 else { return }
        var frame = [Float](repeating: 0, count: channels)
        for f in 0..<framesPerChannel {
            for c in 0..<channels {
                guard let cd = src[c].mData else { continue }
                frame[c] = cd.assumingMemoryBound(to: Float.self)[f]
            }
            frame.withUnsafeBufferPointer { buf in
                if let p = buf.baseAddress { ring.write(p, count: channels) }
            }
        }
    }

    /// 消费者：环形缓冲 → 16kHz 单声道 Int16 → onPCM。所有重活都在这条队列上。
    private func drain(interleaved: AVAudioFormat) {
        guard let ring, let scratch, let converter else { return }
        let channels = Int(interleaved.channelCount)
        while true {
            let got = ring.read(into: scratch, max: scratchCapacity)
            guard got >= channels else { break }
            // 这一块音频**末尾**的真实采集时刻 = 现在 − 缓冲里尚未消费的时长。
            //
            // 直接用「现在」会把 §4 的 T0 时钟整体往后推最多约 120ms（drain 定时器
            // 20ms 粒度 + 单次最多取 100ms）：延迟统计会偏乐观，更要紧的是
            // bankedSilence 少算这段静音，settle 窗口白等一会儿——在 1.8s 的端点
            // 预算里这是实打实的损失。用残留量回推可自我校正：定时器若被推迟，
            // 残留更多，回推也更多。
            let lagNs = UInt64(Double(ring.availableSamples) / Double(channels)
                               / interleaved.sampleRate * 1_000_000_000)
            let frames = AVAudioFrameCount(got / channels)
            guard frames > 0,
                  let inBuf = AVAudioPCMBuffer(pcmFormat: interleaved, frameCapacity: frames),
                  let inCh = inBuf.floatChannelData else { break }
            inBuf.frameLength = frames
            inCh[0].update(from: scratch, count: got)

            // Resample / downmix to 16 kHz mono Int16.
            let ratio = outputFormat.sampleRate / interleaved.sampleRate
            let outCap = AVAudioFrameCount(Double(frames) * ratio) + 1024
            guard let outBuf = AVAudioPCMBuffer(pcmFormat: outputFormat,
                                                frameCapacity: outCap) else { break }
            var fed = false
            var convErr: NSError?
            converter.convert(to: outBuf, error: &convErr) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true
                status.pointee = .haveData
                return inBuf
            }
            if let convErr {
                NSLog("[audio] convert err: %@", convErr.localizedDescription); break
            }
            guard let ch = outBuf.int16ChannelData, outBuf.frameLength > 0 else { break }
            let n = Int(outBuf.frameLength)

            // Diagnostic: throttled level so we can tell if the tap captures real sound.
            var peak = 0
            let p = ch[0]
            for i in 0..<n { let v = abs(Int(p[i])); if v > peak { peak = v } }
            let nowNs = DispatchTime.now().uptimeNanoseconds
            // 回推到本块末尾的采集时刻，而不是处理时刻（见上方 lagNs 的说明）。
            if peak > Self.voiceThreshold { setLastVoiced(nowNs &- lagNs) } // ≈ last phoneme → §4 T0
            dbgFrames += n
            if peak > dbgPeak { dbgPeak = peak }
            if nowNs &- dbgLastNs > 2_000_000_000 {
                let dropped = ring.takeOverflowCount()
                NSLog("[audio] ~%d frames/2s peak=%d overflow=%d (0=silence, >300 = real audio)",
                      dbgFrames, dbgPeak, dropped)
                dbgFrames = 0; dbgPeak = 0; dbgLastNs = nowNs
            }

            onPCM?(Data(bytes: ch[0], count: n * 2))
            if got < scratchCapacity { break }
        }
    }

    /// 启动消费者。在 `AudioDeviceStart` 之前调用（此时 inputFormat/converter 已就绪）。
    private func startDrain(inputFormat inFmt: AVAudioFormat) {
        let channels = Int(inFmt.channelCount)
        guard let interleaved = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                              sampleRate: inFmt.sampleRate,
                                              channels: AVAudioChannelCount(channels),
                                              interleaved: true) else { return }
        drainFormat = interleaved
        ring = PCMRingBuffer(sampleRate: inFmt.sampleRate, channels: channels)
        // 每次最多取 100ms：足够低延迟，也摊薄了每块的固定开销。
        scratchCapacity = Swift.max(1024, Int(inFmt.sampleRate * 0.1) * channels)
        scratch = UnsafeMutablePointer<Float>.allocate(capacity: scratchCapacity)

        let t = DispatchSource.makeTimerSource(queue: drainQueue)
        t.schedule(deadline: .now() + .milliseconds(20),
                   repeating: .milliseconds(20), leeway: .milliseconds(5))
        t.setEventHandler { [weak self] in
            guard let self, let fmt = self.drainFormat else { return }
            self.drain(interleaved: fmt)
        }
        drainTimer = t
        t.resume()
    }

    private func stopDrain() {
        drainTimer?.cancel(); drainTimer = nil
        drainQueue.sync {}                    // 等最后一次 drain 结束再释放 scratch
        scratch?.deallocate(); scratch = nil
        scratchCapacity = 0
        ring = nil
        drainFormat = nil
    }

    private var ring: PCMRingBuffer?
    private var drainFormat: AVAudioFormat?
    private let drainQueue = DispatchQueue(label: "com.notchmeet.audio.drain", qos: .userInitiated)
    private var drainTimer: DispatchSourceTimer?
    private var scratch: UnsafeMutablePointer<Float>?
    private var scratchCapacity = 0

    private var dbgFrames = 0
    private var dbgPeak = 0
    private var dbgLastNs: UInt64 = 0

    // Last-voiced timestamp for §4 T0. 写在 drain 队列、读在 main（turn 开始时）。
    // 旧实现是跨线程裸读写（自认的 §15 遗留，按 Swift 内存模型是 UB）；改用
    // unfair lock 后在 Swift 6 严格并发下也成立。
    private static let voiceThreshold = 300   // matches the "real audio" peak threshold
    private let lastVoiced = OSAllocatedUnfairLock(initialState: UInt64(0))
    private func setLastVoiced(_ ns: UInt64) { lastVoiced.withLock { $0 = ns } }
    var lastVoicedUptimeNs: UInt64 { lastVoiced.withLock { $0 } }
}
