import Foundation

/// Emits canned Japanese interview questions on a timer, so the whole pipeline can
/// be exercised with no audio devices or API keys. Includes a backchannel utterance
/// to verify the TurnManager's backchannel filter.
final class MockSttClient: SttClient {
    var onTranscript: ((Transcript) -> Void)?
    var onError: ((Error) -> Void)?
    var isConnected: Bool { timer != nil }

    private var timer: Timer?
    private var i = 0
    private let script: [Transcript] = [
        Transcript(text: "自己紹介をお願いします。", isFinal: true, confidence: 0.95),
        Transcript(text: "なるほど。", isFinal: true, confidence: 0.9), // backchannel → 应被 TurnManager 过滤
        Transcript(text: "学生時代に力を入れたことを教えてください。", isFinal: true, confidence: 0.94),
        Transcript(text: "当社を志望する理由は何ですか。", isFinal: true, confidence: 0.93),
        Transcript(text: "あなたの強みと弱みを教えてください。", isFinal: true, confidence: 0.92),
        Transcript(text: "最後に何か質問はありますか。", isFinal: true, confidence: 0.95),
    ]

    func start() throws {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.fire() }
        timer = Timer.scheduledTimer(withTimeInterval: 9, repeats: true) { [weak self] _ in self?.fire() }
    }

    func stop() { timer?.invalidate(); timer = nil }

    private func fire() {
        let t = script[i % script.count]
        i += 1
        onTranscript?(t)
    }
}
