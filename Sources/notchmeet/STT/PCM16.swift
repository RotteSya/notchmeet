import AVFoundation
import Foundation

/// 把 16 kHz 单声道 PCM16 小端 `Data`（音频管线 `write(_:)` 的格式）转成
/// `SFSpeechAudioBufferRecognitionRequest` 可 append 的 `AVAudioPCMBuffer`。
enum PCM16 {
    static let sampleRate: Double = 16000

    static func buffer(from data: Data) -> AVAudioPCMBuffer? {
        let frames = AVAudioFrameCount(data.count / MemoryLayout<Int16>.size)
        guard frames > 0,
              let format = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                         sampleRate: sampleRate, channels: 1, interleaved: true),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let dst = buffer.int16ChannelData else { return nil }
        buffer.frameLength = frames
        data.withUnsafeBytes { raw in
            if let base = raw.baseAddress {
                dst.pointee.update(from: base.assumingMemoryBound(to: Int16.self), count: Int(frames))
            }
        }
        return buffer
    }
}
