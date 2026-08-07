import AVFoundation

/// Speaks the onboarding demo's interviewer question out loud. ALWAYS Japanese — a 就活
/// mock interviewer speaks Japanese regardless of whether the UI is set to 中 or 日.
/// Uses Apple's on-device `AVSpeechSynthesizer` (no third-party TTS, no network, no
/// recording permission — this is output only). Output plays through the default device;
/// the caller pauses the live turn pipeline while it speaks so the app's own audio tap
/// doesn't capture it and fire a competing answer.
final class DemoVoice {
    private let synth = AVSpeechSynthesizer()

    /// Speak `text` with a Japanese voice. Cancels any in-flight utterance first (so the
    /// "もう一度 / replay" button restarts cleanly).
    ///
    /// `liveCaptureActive` — onboarding can be reopened MID-INTERVIEW (设置 → 关于 →
    /// 重新运行引导). If the demo then speaks a Japanese interviewer question through the
    /// speakers, the user's OWN microphone carries it straight into Zoom/Meet for the real
    /// interviewer to hear. While the app is recording a live session the demo stays visual
    /// only. Returns whether it will actually speak (the caller surfaces a 🔇 note when not).
    @discardableResult
    func speakJapanese(_ text: String, liveCaptureActive: Bool = false) -> Bool {
        synth.stopSpeaking(at: .immediate)
        guard !liveCaptureActive else { return false }
        let u = AVSpeechUtterance(string: text)
        u.voice = Self.voice
        u.rate = AVSpeechUtteranceDefaultSpeechRate * 0.95   // a measured, natural interviewer pace
        synth.speak(u)
        return true
    }

    func stop() { synth.stopSpeaking(at: .immediate) }

    /// Prefer the highest-quality Kyoko (Apple's standard professional JA voice — uses the
    /// Premium/Enhanced variant when the user has downloaded it), then any Japanese voice.
    /// Resolved once: enumerating voices isn't free and the choice never changes mid-run.
    private static let voice: AVSpeechSynthesisVoice? = {
        let ja = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("ja") }
        let kyoko = ja.filter { $0.name.contains("Kyoko") }.max { $0.quality.rawValue < $1.quality.rawValue }
        return kyoko ?? AVSpeechSynthesisVoice(language: "ja-JP") ?? ja.first
    }()
}
