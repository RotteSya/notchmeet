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
    /// 端侧日语资产缺失时的下载进度（0.0–1.0）。仅本具体类持有，不进 `SttClient` 协议。
    /// 回调可能在任意线程触发，调用方需自行切回主线程更新 UI。
    var onAssetDownloadProgress: ((Double) -> Void)?

    private var recognizer: SFSpeechRecognizer?
    private let localeID: String
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
    private var installing = false // 端侧资产下载进行中（防止重复发起安装请求）

    init(localeID: String = "ja-JP") {
        self.localeID = localeID
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
                    // 端侧日语资产缺失：macOS 26 起可用新 Speech API 主动下载，装好后自动开始；
                    // 更早的系统维持原行为（只能提示用户去系统设置手动开启听写）。
                    if #available(macOS 26.0, *) {
                        self.beginAssetInstall()
                    } else {
                        self.fail(.onDeviceUnavailable)
                    }
                    return
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

    // MARK: - 端侧资产按需下载（macOS 26+）
    //
    // `SFSpeechRecognizer` 的端侧日语资产与键盘听写共用同一套模型。macOS 26 起可用
    // `AssetInventory` / `DictationTranscriber`（同一套资产）主动触发下载并汇报进度，
    // 装好后重建 recognizer 自动开始识别；仍失败才报 `.onDeviceUnavailable`。
    // 下述方法只在 `q` 上被调用/回到 `q` 上改状态；异步下载用 `Task {}` 桥接。

    @available(macOS 26.0, *)
    private func beginAssetInstall() {
        // 仅在 q 上。下载中重复 start() 不发第二个请求，只重新置位 started 以便完成后自动开始。
        guard !installing else { started = true; return }
        started = true
        installing = true
        NSLog("[apple-stt] on-device ja-JP asset missing; requesting install…")
        Task { [weak self] in await self?.performAssetInstall() }
    }

    @available(macOS 26.0, *)
    private func performAssetInstall() async {
        let locale = Locale(identifier: localeID)
        // DictationTranscriber 与 SFSpeechRecognizer/键盘听写共用同一套端侧资产。
        let transcriber = DictationTranscriber(locale: locale, preset: .progressiveShortDictation)
        do {
            if await AssetInventory.status(forModules: [transcriber]) == .installed {
                finishAssetInstall(ok: true); return
            }
            // 预留 locale 配额（固定一个 ja-JP 足够；已预留返回 true，配额满才抛错）。
            _ = try? await AssetInventory.reserve(locale: locale)
            guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else {
                finishAssetInstall(ok: true); return   // nil = 无需下载，资产已就绪
            }
            // 观察进度（Foundation Progress，KVO fractionCompleted），按整百分比节流上报。
            // 只捕获回调本身（不捕获 self），规避 KVO `@Sendable` 闭包对非 Sendable self 的告警。
            let report = onAssetDownloadProgress
            var lastPct = -1
            let obs = request.progress.observe(\.fractionCompleted, options: [.initial, .new]) { p, _ in
                let pct = Int(p.fractionCompleted * 100)
                if pct != lastPct { lastPct = pct; report?(p.fractionCompleted) }
            }
            try await request.downloadAndInstall()
            obs.invalidate()
            finishAssetInstall(ok: true)
        } catch {
            NSLog("[apple-stt] asset install failed: %@", String(describing: error))
            finishAssetInstall(ok: false)
        }
    }

    @available(macOS 26.0, *)
    private func finishAssetInstall(ok: Bool) {
        q.async { [weak self] in
            guard let self else { return }
            self.installing = false
            // 下载期间 stop() 被调用（started 变 false）→ 不要 begin()。
            guard self.started else {
                NSLog("[apple-stt] asset install done but session stopped; skip begin")
                return
            }
            guard ok else { self.fail(.onDeviceUnavailable); return }
            // 资产装好后旧 recognizer 的 supportsOnDeviceRecognition 可能不刷新 → 重建实例再判定。
            guard let rec = SFSpeechRecognizer(locale: Locale(identifier: self.localeID)),
                  rec.supportsOnDeviceRecognition else {
                self.fail(.onDeviceUnavailable); return
            }
            self.recognizer = rec
            NSLog("[apple-stt] ja-JP on-device asset ready; starting recognition")
            self.begin()
        }
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
