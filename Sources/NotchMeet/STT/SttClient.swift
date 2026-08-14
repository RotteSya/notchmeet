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
    /// 用户域名词热词（公司名/职务/技能）。专有名词误识是命中链最上游的死因——
    /// 公司名一旦听错，路由/匹配/grounding 全部救不回。各引擎按自己的机制吃：
    /// Apple → contextualStrings（端侧，不出网）；Deepgram → keywords boost（仅日语，
    /// zh-CN 的关键词支持未实测、误下发可能拒握手）。默认空实现（mock 不用管）。
    func setVocabulary(_ terms: [String])
}

extension SttClient {
    func setLanguage(_ lang: String) {}
    func setVocabulary(_ terms: [String]) {}
    func write(_ pcm: Data) {}
    var isConnected: Bool { false }
}
