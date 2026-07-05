import Foundation

/// 从连续 PCM16 分块流里检测"一句话说完了"的端点：在**至少出现过一次语音之后**，
/// 累计静音样本达到阈值即报告端点（并复位以待下一句）。这样 `AppleSpeechSttClient`
/// 就能复现 Deepgram `speech_final` 的语义，无需依赖 SFSpeech 何时给 isFinal。
///
/// 说明：实时通话中被 tap 的 App 会持续产出音频帧（静音≈低能量帧），因此按"样本数"
/// 计时是确定性的、与墙钟无关，便于测试。
struct UtteranceEndpointer {
    private let silenceThreshold: Double      // 归一化 RMS [0,1]，低于此视为静音
    private let silenceSamplesToEndpoint: Int // 触发端点所需的连续静音样本数
    private var sawVoice = false
    private var silentRun = 0

    init(silenceThreshold: Double = 0.012, silenceSamplesToEndpoint: Int = 11200) {
        self.silenceThreshold = silenceThreshold
        self.silenceSamplesToEndpoint = silenceSamplesToEndpoint
    }

    /// 喂入一块 PCM16；仅在跨过端点的那一次返回 true。
    mutating func feed(_ pcm: Data) -> Bool {
        let (rms, samples) = Self.rms(pcm)
        guard samples > 0 else { return false }
        if rms >= silenceThreshold {
            sawVoice = true
            silentRun = 0
            return false
        }
        guard sawVoice else { return false }   // 忽略开头的静音
        silentRun += samples
        if silentRun >= silenceSamplesToEndpoint {
            sawVoice = false
            silentRun = 0
            return true
        }
        return false
    }

    /// 归一化 RMS（Int16→[-1,1]）与样本数。
    static func rms(_ data: Data) -> (rms: Double, samples: Int) {
        let n = data.count / MemoryLayout<Int16>.size
        guard n > 0 else { return (0, 0) }
        var sumSq = 0.0
        data.withUnsafeBytes { raw in
            let p = raw.bindMemory(to: Int16.self)
            for i in 0..<n {
                let v = Double(Int16(littleEndian: p[i])) / 32768.0
                sumSq += v * v
            }
        }
        return ((sumSq / Double(n)).squareRoot(), n)
    }
}
