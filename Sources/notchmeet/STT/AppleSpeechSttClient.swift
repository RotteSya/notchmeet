import AVFoundation
import Foundation
import Speech

/// 端侧离线日语 STT（`SFSpeechRecognizer`，`requiresOnDeviceRecognition`）。国内兜底 Deepgram。
/// 吃与 Deepgram 相同的 16kHz 单声道 PCM16 流（`write(_:)`），用 `UtteranceEndpointer` 做静音
/// 端点、轮转识别任务以复现 Deepgram 的 final 语义（`TurnManager` 无需改动），并规避连续识别的
/// 时长上限。所有可变状态只在串行队列 `q` 上访问。
final class AppleSpeechSttClient: NSObject, SttClient {
    var onTranscript: ((Transcript) -> Void)?
    var onError: ((Error) -> Void)?

    private let recognizer: SFSpeechRecognizer?
    private let q = DispatchQueue(label: "notchmeet.applestt")

    private let lock = NSLock()
    private var _connected = false
    var isConnected: Bool { lock.lock(); defer { lock.unlock() }; return _connected }
    private func setConnected(_ v: Bool) { lock.lock(); _connected = v; lock.unlock() }

    // 以下只在 `q` 上访问：
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var endpointer = UtteranceEndpointer()
    private var pendingText = ""
    private var lastConf = 0.0
    private var generation = 0     // 轮转令牌：忽略旧任务的滞后回调
    private var started = false

    init(localeID: String = "ja-JP") {
        recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeID))
        super.init()
    }

    /// 产品固定 ja-JP（见 spec 非目标）；保留以满足协议。
    func setLanguage(_ lang: String) {}

    func start() throws {
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            guard let self else { return }
            self.q.async {
                guard status == .authorized else { self.fail(.notAuthorized); return }
                guard let rec = self.recognizer, rec.isAvailable, rec.supportsOnDeviceRecognition else {
                    self.fail(.onDeviceUnavailable); return
                }
                self.started = true
                self.begin()
            }
        }
    }

    func stop() {
        setConnected(false)
        q.async { [weak self] in
            guard let self else { return }
            self.started = false
            self.generation &+= 1
            self.task?.cancel(); self.task = nil
            self.request = nil
            self.pendingText = ""
        }
    }

    func write(_ pcm: Data) {
        guard isConnected else { return }   // socket-down 语义：未连接直接丢
        q.async { [weak self] in self?.ingest(pcm) }
    }

    // MARK: - 仅在 q 上

    private func begin() {
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.requiresOnDeviceRecognition = true
        req.shouldReportPartialResults = true
        if #available(macOS 13, *) { req.addsPunctuation = true }
        request = req
        endpointer = UtteranceEndpointer()
        pendingText = ""
        let gen = generation
        task = recognizer?.recognitionTask(with: req) { [weak self] result, error in
            self?.q.async { self?.handle(result: result, error: error, gen: gen) }
        }
        setConnected(true)
        NSLog("[apple-stt] task started (gen %d)", gen)
    }

    private func ingest(_ pcm: Data) {
        guard let req = request, let buf = PCM16.buffer(from: pcm) else { return }
        req.append(buf)
        if endpointer.feed(pcm) { rotate() }   // 静音端点 → 收束当前一句并轮转
    }

    private func handle(result: SFSpeechRecognitionResult?, error: Error?, gen: Int) {
        guard gen == generation else { return }   // 旧任务的滞后回调，丢弃
        if let result {
            let text = result.bestTranscription.formattedString
            lastConf = Self.avgConfidence(result.bestTranscription)
            if !text.isEmpty { pendingText = text }
            if result.isFinal {                    // SFSpeech 自行判定结束 → 收束并重启
                rotate()
                return
            } else if !text.isEmpty {
                onTranscript?(Transcript(text: text, isFinal: false, confidence: lastConf))
            }
        }
        if error != nil, started { restart() }     // 任务出错 → 重启
    }

    /// 端点/结束：把缓冲的一句作为 final emit，然后开一个新任务。
    private func rotate() {
        emitFinal()
        restart()
    }

    private func restart() {
        generation &+= 1
        task?.cancel(); task = nil
        request = nil
        if started { begin() }
    }

    private func emitFinal() {
        let t = pendingText.trimmingCharacters(in: .whitespacesAndNewlines)
        pendingText = ""
        guard !t.isEmpty else { return }
        onTranscript?(Transcript(text: t, isFinal: true, confidence: lastConf))
    }

    private func fail(_ e: SttError) {
        setConnected(false)
        NSLog("[apple-stt] unavailable: %@", String(describing: e))
        onError?(e)
    }

    private static func avgConfidence(_ t: SFTranscription) -> Double {
        guard !t.segments.isEmpty else { return 0 }
        return t.segments.map { Double($0.confidence) }.reduce(0, +) / Double(t.segments.count)
    }
}

enum SttError: Error, LocalizedError {
    case notAuthorized
    case onDeviceUnavailable

    var errorDescription: String? {
        switch self {
        case .notAuthorized:      return AppStrings.current.sttNotAuthorized
        case .onDeviceUnavailable: return AppStrings.current.sttLocalUnavailable
        }
    }
}
