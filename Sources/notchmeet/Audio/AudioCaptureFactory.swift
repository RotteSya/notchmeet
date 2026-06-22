import Foundation

enum AudioCaptureFactory {
    /// Live capture: taps ONLY the resolved call app (never all system audio).
    static func make() -> AudioCapture {
        if #available(macOS 14.4, *) {
            return CoreAudioTapCapture(target: .callApp)
        }
        NSLog("[audio] macOS < 14.4 — no process tap; using null capture")
        return NullAudioCapture()
    }

    /// Permission probe only: a throwaway tap used to trigger the macOS audio-capture TCC
    /// prompt during onboarding. Captures nothing and is torn down immediately.
    static func makeProbe() -> AudioCapture {
        if #available(macOS 14.4, *) {
            return CoreAudioTapCapture(target: .probeGlobal)
        }
        return NullAudioCapture()
    }
}
