import Foundation
import AVFoundation
import CoreAudio
import AudioToolbox

/// Captures the OUTPUT audio of a SINGLE target app (the call app) via a Core Audio
/// process tap + private aggregate device (macOS 14.4+), converts to 16 kHz mono PCM16,
/// and emits it via `onPCM`. No BlackHole / virtual device.
///
/// `.callApp` mode resolves the target with `AudioTargetResolver` (only the call app's
/// audio is captured — never all system audio; that is the privacy promise the page makes).
/// `.probeGlobal` mode is used ONLY to trigger the macOS audio-capture permission prompt
/// during onboarding: it captures nothing (no `onPCM`) and is torn down immediately.
/// Conversion runs inline on the IO thread for now; moving to a lock-free ring buffer is a
/// §14.4 follow-up.
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
        converter = AVAudioConverter(from: inFmt, to: outputFormat)

        // 4. IO proc → conversion → onPCM.
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
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
    }

    private func handle(_ inData: UnsafePointer<AudioBufferList>) {
        guard let inFmt = inputFormat, let converter else { return }
        let src = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
        let bytesPerFrame = inFmt.streamDescription.pointee.mBytesPerFrame
        guard bytesPerFrame > 0, let first = src.first else { return }
        let frames = AVAudioFrameCount(first.mDataByteSize / bytesPerFrame)
        guard frames > 0,
              let inBuf = AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: frames) else { return }
        inBuf.frameLength = frames

        // Copy raw buffers into the input AVAudioPCMBuffer.
        let dst = UnsafeMutableAudioBufferListPointer(inBuf.mutableAudioBufferList)
        for i in 0..<min(src.count, dst.count) {
            if let s = src[i].mData, let d = dst[i].mData {
                memcpy(d, s, Int(src[i].mDataByteSize))
                dst[i].mDataByteSize = src[i].mDataByteSize
            }
        }

        // Resample / downmix to 16 kHz mono Int16.
        let ratio = outputFormat.sampleRate / inFmt.sampleRate
        let outCap = AVAudioFrameCount(Double(frames) * ratio) + 1024
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outCap) else { return }
        var fed = false
        var convErr: NSError?
        converter.convert(to: outBuf, error: &convErr) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return inBuf
        }
        if let convErr { NSLog("[audio] convert err: %@", convErr.localizedDescription); return }
        guard let ch = outBuf.int16ChannelData, outBuf.frameLength > 0 else { return }
        let n = Int(outBuf.frameLength)

        // Diagnostic: throttled level so we can tell if the tap captures real sound.
        var peak = 0
        let p = ch[0]
        for i in 0..<n { let v = abs(Int(p[i])); if v > peak { peak = v } }
        dbgFrames += n
        if peak > dbgPeak { dbgPeak = peak }
        let nowNs = DispatchTime.now().uptimeNanoseconds
        if peak > Self.voiceThreshold { lastVoicedNs = nowNs } // ≈ last phoneme → §4 T0
        if nowNs &- dbgLastNs > 2_000_000_000 {
            NSLog("[audio] ~%d frames/2s peak=%d (0=silence, >300 = real audio)", dbgFrames, dbgPeak)
            dbgFrames = 0; dbgPeak = 0; dbgLastNs = nowNs
        }

        let data = Data(bytes: ch[0], count: n * 2)
        onPCM?(data)
    }

    private var dbgFrames = 0
    private var dbgPeak = 0
    private var dbgLastNs: UInt64 = 0

    // Last-voiced timestamp for §4 T0. Written on the IO thread, read on main at turn
    // start; an aligned UInt64 load/store is atomic enough for this diagnostic value
    // (Swift6 strict concurrency is a deferred §15 follow-up).
    private static let voiceThreshold = 300   // matches the "real audio" peak threshold
    private var lastVoicedNs: UInt64 = 0
    var lastVoicedUptimeNs: UInt64 { lastVoicedNs }
}
