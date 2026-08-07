import XCTest
@testable import notchmeet

/// E5：引导 demo 的 TTS 在面试录音进行中必须静音——扬声器朗读的日语问题会被
/// 自己的麦克风采进 Zoom/Meet，面试官听得一清二楚。
final class DemoVoiceTests: XCTestCase {

    /// 录音进行中 → 拒绝出声，并把「没说」告诉调用方（UI 据此显示 🔇 说明）。
    /// 只测静音路径：出声路径会在测试机上真的播放语音，不适合无人值守跑。
    func testSpeakIsSuppressedWhileLiveCaptureIsActive() {
        let voice = DemoVoice()
        XCTAssertFalse(voice.speakJapanese("志望動機について教えてください。", liveCaptureActive: true),
                       "面试录音进行中 demo 不能出声")
    }
}
