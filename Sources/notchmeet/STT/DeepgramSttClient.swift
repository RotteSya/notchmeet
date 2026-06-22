import Foundation

/// Deepgram streaming STT over WebSocket. Params lifted from Vijaysingh's working
/// config (PLAN §14.2): nova-2 / interim / smart_format / endpointing:300 /
/// utterance_end_ms:1000 / vad_events. We treat `speech_final` (endpoint) as the
/// question-complete final; plain `is_final` segments are interim. Auto-reconnects.
final class DeepgramSttClient: NSObject, SttClient, URLSessionWebSocketDelegate {
    var onTranscript: ((Transcript) -> Void)?
    var onError: ((Error) -> Void)?

    private let apiKey: String
    private var language: String
    private var task: URLSessionWebSocketTask?
    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    private var keepAlive: Timer?
    private var started = false
    private(set) var isConnected = false
    private var reconnectDelay: TimeInterval = 0.5
    private var pendingFinal = ""
    private var lastConf = 0.0
    private let dbg = ProcessInfo.processInfo.environment["FI_STT_DEBUG"] == "1"

    init(apiKey: String, language: String) {
        self.apiKey = apiKey
        self.language = language
    }

    func setLanguage(_ lang: String) { language = lang }

    func start() throws { started = true; isConnected = false; connect() }

    func stop() {
        started = false
        isConnected = false
        keepAlive?.invalidate(); keepAlive = nil
        task?.cancel(with: .goingAway, reason: nil); task = nil
    }

    func write(_ pcm: Data) {
        // Drop audio while the socket is down/reconnecting — sending to a dead task only
        // logs errors and Deepgram wouldn't receive it anyway. Drops happen during silence
        // (that's when idle sockets die), so no interviewer speech is lost.
        guard isConnected else { return }
        task?.send(.data(pcm)) { err in
            if let err { NSLog("[deepgram] send err: %@", String(describing: err)) }
        }
    }

    private func connect() {
        var c = URLComponents(string: "wss://api.deepgram.com/v1/listen")!
        c.queryItems = [
            .init(name: "model", value: "nova-2"),
            .init(name: "language", value: language),
            .init(name: "encoding", value: "linear16"),
            .init(name: "sample_rate", value: "16000"),
            .init(name: "channels", value: "1"),
            .init(name: "interim_results", value: "true"),
            .init(name: "smart_format", value: "true"),
            .init(name: "punctuate", value: "true"),
            .init(name: "endpointing", value: "300"),
            .init(name: "utterance_end_ms", value: "1000"),
            .init(name: "vad_events", value: "true"),
        ]
        // nova-2 keyword boosting (legacy `keywords` param; nova-3's `keyterm` is a different
        // feature) — bias toward 就活 domain vocab (御社/志望動機/外食産業…).
        let keywords = ["御社", "志望動機", "志望理由", "自己紹介", "ガクチカ", "学生時代",
                        "強み", "弱み", "長所", "短所", "きっかけ", "外食産業", "人手不足",
                        "課題", "達成", "努力", "チーム", "リーダー", "逆質問", "キャリア"]
        c.queryItems? += keywords.map { URLQueryItem(name: "keywords", value: $0) }
        guard let url = c.url else { onError?(LLMError.badURL); return }
        var r = URLRequest(url: url)
        r.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")
        let t = session.webSocketTask(with: r)
        task = t
        t.resume()
        receive()
        keepAlive?.invalidate()
        keepAlive = Timer.scheduledTimer(withTimeInterval: 8, repeats: true) { [weak self] _ in
            guard let self, self.isConnected else { return }
            self.task?.send(.string("{\"type\":\"KeepAlive\"}")) { _ in }
        }
    }

    private func receive() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let err):
                self.isConnected = false
                // If we initiated the teardown (stop() cancels the socket), the resulting
                // ENOTCONN is expected — don't surface it as an error or try to reconnect.
                guard self.started else { return }
                self.onError?(err)
                self.scheduleReconnect()
            case .success(let msg):
                switch msg {
                case .string(let s): self.handle(s)
                case .data(let d): if let s = String(data: d, encoding: .utf8) { self.handle(s) }
                @unknown default: break
                }
                if self.started { self.receive() }
            }
        }
    }

    private func handle(_ s: String) {
        guard let d = s.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return }
        let type = o["type"] as? String
        if type == "Error" || o["error"] != nil {
            NSLog("[deepgram] %@", String(s.prefix(300))); return
        }
        if type == "UtteranceEnd" {
            if dbg { NSLog("[deepgram] UtteranceEnd (pending='%@')", pendingFinal) }
            flushPending(); return
        }
        guard let ch = o["channel"] as? [String: Any],
              let alts = ch["alternatives"] as? [[String: Any]],
              let text = alts.first?["transcript"] as? String, !text.isEmpty else { return }
        let isFinal = o["is_final"] as? Bool ?? false
        let speechFinal = o["speech_final"] as? Bool ?? false
        lastConf = alts.first?["confidence"] as? Double ?? lastConf
        if dbg { NSLog("[deepgram] t='%@' is_final=%d speech_final=%d", text, isFinal ? 1 : 0, speechFinal ? 1 : 0) }
        if isFinal { pendingFinal += text }
        // Finalize on Deepgram's endpoint (speech_final) OR a sentence boundary on a
        // finalized segment — continuous audio rarely yields speech_final.
        if speechFinal || (isFinal && Self.endsSentence(text)) {
            flushPending()
        } else {
            onTranscript?(Transcript(text: text, isFinal: false, confidence: lastConf)) // interim
        }
    }

    private static func endsSentence(_ s: String) -> Bool {
        guard let last = s.trimmingCharacters(in: .whitespaces).last else { return false }
        return "。．！？!?".contains(last)
    }

    /// Emit the accumulated final transcript (on speech_final or UtteranceEnd).
    private func flushPending() {
        let t = pendingFinal.trimmingCharacters(in: .whitespacesAndNewlines)
        pendingFinal = ""
        guard !t.isEmpty else { return }
        onTranscript?(Transcript(text: t, isFinal: true, confidence: lastConf))
    }

    private func scheduleReconnect() {
        guard started else { return }
        isConnected = false
        pendingFinal = ""                            // drop a stale partial across the gap
        let delay = reconnectDelay
        reconnectDelay = min(reconnectDelay * 2, 5)  // fast recovery — this is a live interview
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.started else { return }
            NSLog("[deepgram] reconnecting after %.1fs", delay)
            self.connect()
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        reconnectDelay = 0.5
        isConnected = true
        NSLog("[deepgram] connected (%@)", language)
    }
}
