import Foundation

enum AudioError: Error, LocalizedError {
    case tap(OSStatus)
    case aggregate(OSStatus)
    case format(OSStatus)
    case ioproc(OSStatus)
    case start(OSStatus)
    /// No call app to capture — we refuse to fall back to recording all system audio.
    case noCallApp

    var errorDescription: String? {
        switch self {
        case .tap(let s): return "create tap failed (\(s))"
        case .aggregate(let s): return "create aggregate device failed (\(s))"
        case .format(let s): return "read stream format failed (\(s))"
        case .ioproc(let s): return "create IO proc failed (\(s))"
        case .start(let s): return "start device failed (\(s))"
        case .noCallApp: return "no call app detected to capture"
        }
    }
}
