import Foundation

/// Captures the interviewer's audio as 16 kHz mono PCM16 little-endian.
/// macOS impl uses a Core Audio process tap (PLAN §3 S1); NullAudioCapture is a
/// no-op used by mock mode.
protocol AudioCapture: AnyObject {
    var onPCM: ((Data) -> Void)? { get set }
    /// Uptime (ns) of the last speech-level audio frame — approximates the interviewer's
    /// last phoneme (true T0 for the §4 SLA). 0 when unknown (mock / null capture).
    var lastVoicedUptimeNs: UInt64 { get }
    func start() throws
    func stop()
}

extension AudioCapture {
    var lastVoicedUptimeNs: UInt64 { 0 }
}

final class NullAudioCapture: AudioCapture {
    var onPCM: ((Data) -> Void)?
    func start() throws {}
    func stop() {}
}
