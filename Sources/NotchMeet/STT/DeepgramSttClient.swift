import Foundation
import os

/// Deepgram streaming STT over WebSocket. Params lifted from Vijaysingh's working
/// config (PLAN §14.2): nova-2 / interim / smart_format / endpointing:300 /
/// utterance_end_ms:1000 / vad_events. We treat `speech_final` (endpoint) as the
/// question-complete final; plain `is_final` segments are interim.
///
/// **执行域契约**：除 `write()` 与 `isConnected` 外，一切状态只在 `q` 上读写。
/// 旧实现把 `task`/`started` 暴露给 main、URLSession delegate 队列、CoreAudio 音频
/// 线程三方裸访问，由此产生三个同根问题，这里一并收编：
///
/// 1. **代际令牌**：每次 `connect()` 递增 `generation`，所有回调先验代际。
///    旧实现在 stop→start 快速切换时，旧 socket 的失败回调会看到 `started == true`
///    而触发重连，造出第二条活着的转录流——同一句话被两路各出一次 final。
/// 2. **接收侧看门狗**：只要在发音频却持续收不到任何服务端帧，就主动重连。
///    半开 TCP（梯子换节点 / WiFi 漂移，中国区常见）不会产生 RST，旧实现要等内核
///    TCP 超时（可达分钟级）才发现，期间面试官的每一句话都静默蒸发。
/// 3. **永久性故障上报**：连续多次失败（key 撤销 / 欠费 / 长期无网）冒泡 `SttError`，
///    而不是无限静默重连——旧实现下用户会盯着「聆听中」度过整场没有转写的面试。
final class DeepgramSttClient: NSObject, SttClient, URLSessionWebSocketDelegate {
    var onTranscript: ((Transcript) -> Void)?
    var onError: ((Error) -> Void)?

    private let apiKey: String
    private let q = DispatchQueue(label: "com.notchmeet.deepgram")

    // MARK: 只在 q 上访问
    private var language: String
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var generation: UInt64 = 0
    private var started = false
    private var reconnectDelay: TimeInterval = 0.5
    private var consecutiveFailures = 0
    private var pendingFinal = ""
    private var lastConf = 0.0
    private var lastServerNs: UInt64 = 0
    private var sentAudioSinceServerMsg = false
    private var watchdog: DispatchSourceTimer?
    private var keepAlive: DispatchSourceTimer?

    /// `write()` 从音频链路调用，只碰这一个锁保护的小状态（临界区仅两次读）。
    private let sendState = OSAllocatedUnfairLock(
        initialState: SendState(connected: false, task: nil))
    private struct SendState {
        var connected: Bool
        var task: URLSessionWebSocketTask?
    }

    private let dbg = ProcessInfo.processInfo.environment["FI_STT_DEBUG"] == "1"

    /// 连续这么多次连接失败后判定为永久故障，冒泡给用户。
    static let maxConsecutiveFailures = 4
    /// 发着音频却这么久收不到任何服务端帧 → 判定半开，主动重连。
    static let serverSilenceTimeoutNs: UInt64 = 5_000_000_000

    init(apiKey: String, language: String) {
        self.apiKey = apiKey
        self.language = language
    }

    deinit {
        session?.invalidateAndCancel()
    }

    func setLanguage(_ lang: String) { q.async { self.language = lang } }

    var isConnected: Bool { sendState.withLock { $0.connected } }

    func start() throws {
        q.async {
            guard !self.started else { return }
            self.started = true
            self.consecutiveFailures = 0
            self.reconnectDelay = 0.5
            self.connectLocked()
            self.startWatchdogLocked()
        }
    }

    func stop() {
        q.async {
            self.started = false
            self.generation &+= 1          // 让所有在途回调立即失效
            self.teardownLocked()
            self.watchdog?.cancel(); self.watchdog = nil
            self.keepAlive?.cancel(); self.keepAlive = nil
            // URLSession 强持 delegate(self)：不 invalidate 就是每次 reloadPipeline
            // （改 Key / 兑码）泄漏一个客户端 + 一条 session 工作线程。
            self.session?.finishTasksAndInvalidate()
            self.session = nil
        }
    }

    /// 音频链路调用。只读锁保护的 (connected, task)，不进 `q`（避免每 ~20ms 一次派发）。
    func write(_ pcm: Data) {
        let state = sendState.withLock { $0 }
        // Drop audio while the socket is down/reconnecting — sending to a dead task only
        // logs errors and Deepgram wouldn't receive it anyway.
        guard state.connected, let t = state.task else { return }
        t.send(.data(pcm)) { [weak self] err in
            guard let self, let err else { return }
            NSLog("[deepgram] send err: %@", String(describing: err))
            self.q.async { self.noteSendFailureLocked() }
        }
        q.async { self.sentAudioSinceServerMsg = true }
    }

    // MARK: - 连接生命周期（全部在 q 上）

    private func connectLocked() {
        teardownLocked()
        generation &+= 1
        let gen = generation

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

        if session == nil {
            session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        }
        guard let session else { return }
        var r = URLRequest(url: url)
        r.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")
        let t = session.webSocketTask(with: r)
        task = t
        lastServerNs = DispatchTime.now().uptimeNanoseconds
        sentAudioSinceServerMsg = false
        t.resume()
        receiveLocked(gen: gen, task: t)
        startKeepAliveLocked(gen: gen)
    }

    private func teardownLocked() {
        sendState.withLock { $0 = SendState(connected: false, task: nil) }
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    private func startKeepAliveLocked(gen: UInt64) {
        keepAlive?.cancel()
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now() + 8, repeating: .seconds(8), leeway: .seconds(2))
        t.setEventHandler { [weak self] in
            guard let self, gen == self.generation, self.started,
                  let task = self.task, self.isConnected else { return }
            task.send(.string("{\"type\":\"KeepAlive\"}")) { _ in }
        }
        keepAlive = t
        t.resume()
    }

    private func receiveLocked(gen: UInt64, task t: URLSessionWebSocketTask) {
        t.receive { [weak self] result in
            guard let self else { return }
            self.q.async {
                // 代际校验：旧 socket 的回调一律丢弃，不得复活成第二条转录流。
                guard gen == self.generation, self.started else { return }
                switch result {
                case .failure(let err):
                    self.sendState.withLock { $0.connected = false }
                    self.consecutiveFailures += 1
                    NSLog("[deepgram] recv err (%d/%d): %@", self.consecutiveFailures,
                          Self.maxConsecutiveFailures, String(describing: err))
                    if self.consecutiveFailures >= Self.maxConsecutiveFailures {
                        // 永久性故障：必须让用户看见，否则整场面试显示「聆听中」却零转写。
                        self.started = false
                        self.teardownLocked()
                        self.watchdog?.cancel(); self.watchdog = nil
                        self.keepAlive?.cancel(); self.keepAlive = nil
                        self.onError?(SttError.streamUnavailable(
                            detail: (err as NSError).localizedDescription))
                        return
                    }
                    self.onError?(err)
                    self.scheduleReconnectLocked()
                case .success(let msg):
                    self.lastServerNs = DispatchTime.now().uptimeNanoseconds
                    self.sentAudioSinceServerMsg = false
                    self.consecutiveFailures = 0
                    switch msg {
                    case .string(let s): self.handleLocked(s)
                    case .data(let d):
                        if let s = String(data: d, encoding: .utf8) { self.handleLocked(s) }
                    @unknown default: break
                    }
                    self.receiveLocked(gen: gen, task: t)
                }
            }
        }
    }

    private func noteSendFailureLocked() {
        consecutiveFailures += 1
        guard consecutiveFailures >= Self.maxConsecutiveFailures, started else { return }
        NSLog("[deepgram] repeated send failures — forcing reconnect")
        consecutiveFailures = 0
        scheduleReconnectLocked()
    }

    /// 接收侧看门狗：在发音频却长时间零服务端帧 = 半开连接。
    private func startWatchdogLocked() {
        watchdog?.cancel()
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now() + 2, repeating: .seconds(2), leeway: .milliseconds(500))
        t.setEventHandler { [weak self] in
            guard let self, self.started, self.sentAudioSinceServerMsg else { return }
            let elapsed = DispatchTime.now().uptimeNanoseconds &- self.lastServerNs
            guard elapsed > Self.serverSilenceTimeoutNs else { return }
            NSLog("[deepgram] watchdog: %.1fs server silence while sending — reconnecting",
                  Double(elapsed) / 1e9)
            self.sentAudioSinceServerMsg = false
            self.scheduleReconnectLocked()
        }
        watchdog = t
        t.resume()
    }

    private func handleLocked(_ s: String) {
        guard let d = s.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return }
        let type = o["type"] as? String
        if type == "Error" || o["error"] != nil {
            // 只打类型，不打 body——里面含面试官问题原文，会进系统 unified log。
            NSLog("[deepgram] server error (type=%@)", type ?? "?")
            return
        }
        if type == "UtteranceEnd" {
            if dbg { NSLog("[deepgram] UtteranceEnd (pending=%d chars)", pendingFinal.count) }
            flushPendingLocked(); return
        }
        guard let ch = o["channel"] as? [String: Any],
              let alts = ch["alternatives"] as? [[String: Any]],
              let text = alts.first?["transcript"] as? String, !text.isEmpty else { return }
        let isFinal = o["is_final"] as? Bool ?? false
        let speechFinal = o["speech_final"] as? Bool ?? false
        lastConf = alts.first?["confidence"] as? Double ?? lastConf
        if dbg {
            NSLog("[deepgram] %d chars is_final=%d speech_final=%d",
                  text.count, isFinal ? 1 : 0, speechFinal ? 1 : 0)
        }
        if isFinal { pendingFinal += text }
        // Finalize on Deepgram's endpoint (speech_final) OR a sentence boundary on a
        // finalized segment — continuous audio rarely yields speech_final.
        if speechFinal || (isFinal && Self.endsSentence(text)) {
            flushPendingLocked()
        } else {
            onTranscript?(Transcript(text: text, isFinal: false, confidence: lastConf)) // interim
        }
    }

    static func endsSentence(_ s: String) -> Bool {
        guard let last = s.trimmingCharacters(in: .whitespaces).last else { return false }
        return "。．！？!?".contains(last)
    }

    /// Emit the accumulated final transcript (on speech_final or UtteranceEnd).
    private func flushPendingLocked() {
        let t = pendingFinal.trimmingCharacters(in: .whitespacesAndNewlines)
        pendingFinal = ""
        guard !t.isEmpty else { return }
        onTranscript?(Transcript(text: t, isFinal: true, confidence: lastConf))
    }

    private func scheduleReconnectLocked() {
        guard started else { return }
        sendState.withLock { $0 = SendState(connected: false, task: nil) }
        pendingFinal = ""                            // drop a stale partial across the gap
        let delay = reconnectDelay
        reconnectDelay = min(reconnectDelay * 2, 5)  // fast recovery — this is a live interview
        q.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.started else { return }
            NSLog("[deepgram] reconnecting after %.1fs", delay)
            self.connectLocked()
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        q.async {
            guard webSocketTask === self.task, self.started else { return }
            self.reconnectDelay = 0.5
            self.consecutiveFailures = 0
            self.lastServerNs = DispatchTime.now().uptimeNanoseconds
            self.sendState.withLock { $0 = SendState(connected: true, task: webSocketTask) }
            NSLog("[deepgram] connected (%@)", self.language)
        }
    }
}
