import Foundation

/// One streaming transcript event.
struct Transcript {
    let text: String
    let isFinal: Bool      // true = utterance/endpoint finalized by the provider
    let confidence: Double
}

/// Streaming speech-to-text. Implementations: MockSttClient, DeepgramSttClient, …
/// (Provider-abstraction pattern lifted from Natively; PLAN §5.)
protocol SttClient: AnyObject {
    var onTranscript: ((Transcript) -> Void)? { get set }
    var onError: ((Error) -> Void)? { get set }
    /// True while the streaming connection is established (pre-interview self-check).
    var isConnected: Bool { get }

    func start() throws
    func stop()
    /// Feed 16 kHz mono PCM16 little-endian audio (the interviewer channel).
    func write(_ pcm: Data)
    func setLanguage(_ lang: String)
}

extension SttClient {
    func setLanguage(_ lang: String) {}
    func write(_ pcm: Data) {}
    var isConnected: Bool { false }
}
