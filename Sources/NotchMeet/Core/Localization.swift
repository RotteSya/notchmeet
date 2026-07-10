import Combine
import Foundation

enum UILanguage: String, CaseIterable {
    case zh
    case ja
}

enum InterviewLanguage: String {
    case japanese = "ja"

    var deepgramCode: String { rawValue }
}

enum RuntimeMessage: Equatable {
    case ready
    case listening
    case thinking
    case suggesting
    case completed
    case apiKeyMissing
    case autoStopped
    case bankGenerating
    case startupError
    case generationError
    case sttError
    case creditLow        // 额度即将用完（录音继续，短暂提示后回到聆听态）
    case creditExhausted  // 额度归零：会话已被停止，需要充值
}

enum CaptureHealthState {
    case notStarted
    case noKeyOrDemo
    case permissionRequired
    case paused
    case voiceDetected
    case ready
}

/// One durable UI-language source for every app surface. The legacy `nm_lang`
/// preference is read and mirrored so existing installs keep their selection.
final class AppLanguageStore: ObservableObject {
    static let shared = AppLanguageStore()

    @Published var language: UILanguage {
        didSet {
            defaults.set(language.rawValue, forKey: Self.preferenceKey)
            defaults.set(language.rawValue, forKey: Self.legacyPreferenceKey)
        }
    }

    private static let preferenceKey = "nm_ui_language"
    private static let legacyPreferenceKey = "nm_lang"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.string(forKey: Self.preferenceKey)
            ?? defaults.string(forKey: Self.legacyPreferenceKey)
        self.language = stored.flatMap(UILanguage.init(rawValue:)) ?? .zh
    }
}

/// Compact typed copy layer. Product content (the Japanese interview question and
/// answer) remains Japanese; chrome, controls, health, and errors follow UI language.
struct AppStrings {
    let language: UILanguage

    static var current: AppStrings { AppStrings(language: AppLanguageStore.shared.language) }

    private func pick(_ zh: String, _ ja: String) -> String { language == .zh ? zh : ja }

    var notchTitle: String { pick("面试提词器", "面接プロンプター") }
    /// Prefix for the recognized-question line in the notch (lets the user catch a mis-hear).
    var heardLabel: String { pick("听到", "聞き取り") }
    var settings: String { pick("设置", "設定") }
    var interviewLanguageName: String { pick("日语", "日本語") }
    var uiLanguageName: String { language == .zh ? "中文" : "日本語" }
    var languageSummaryLabel: String { pick("语言", "言語") }
    var languageSummaryValue: String {
        pick("界面：中文 · 面试与回答：日语", "画面：日本語・面接と回答：日本語")
    }

    func runtimeMessage(_ message: RuntimeMessage) -> String {
        switch message {
        case .ready: return pick("待机中 · 点击圆点或 ⌘⇧P 开始录音", "待機中 · ●をタップ／⌘⇧Pで録音開始")
        case .listening: return pick("聆听中…", "聞き取り中…")
        case .thinking: return pick("思考中…", "考え中…")
        case .suggesting: return pick("生成建议中…", "提案中…")
        case .completed: return pick("完成", "完了")
        case .apiKeyMissing: return pick("服务尚未开通（点击右侧设置激活）", "サービスが未開通です（右側の設定から有効化）")
        case .autoStopped: return pick("因长时间无发言已自动停止录音", "発言がないため録音を自動停止")
        case .bankGenerating: return pick("正在预生成回答…", "回答を事前生成中…")
        case .startupError: return pick("启动失败", "起動エラー")
        case .generationError: return pick("回答生成失败", "回答生成エラー")
        case .sttError: return pick("语音识别不可用", "音声認識が利用できません")
        case .creditLow: return pick("额度即将用完——面试结束后记得充值", "残り時間わずか——面接後にチャージをお忘れなく")
        case .creditExhausted: return pick("额度已用完，充值后即可继续使用", "残高がなくなりました。チャージすると続けて使えます")
        }
    }

    /// Short status copy for the notch header. The longer runtime message remains available
    /// in the body when there is no answer yet.
    func notchStatus(_ message: RuntimeMessage) -> String {
        switch message {
        case .ready: return pick("待机", "待機")
        case .listening: return pick("聆听中", "聞き取り中")
        case .thinking: return pick("整理问题", "質問を整理中")
        case .suggesting: return pick("生成回答", "回答を生成中")
        case .completed: return pick("可直接作答", "そのまま回答できます")
        case .apiKeyMissing: return pick("需要激活服务", "サービスの有効化が必要")
        case .autoStopped: return pick("已自动停止", "自動停止しました")
        case .bankGenerating: return pick("准备回答中", "回答を準備中")
        case .startupError, .generationError, .sttError: return pick("需要处理", "確認が必要です")
        case .creditLow: return pick("额度即将用完", "残りわずか")
        case .creditExhausted: return pick("额度已用完", "残高がありません")
        }
    }

    func generationError(_ detail: String) -> String {
        pick("（回答生成失败：\(detail)）", "（回答生成エラー：\(detail)）")
    }

    var copyAnswer: String { pick("拷贝回答", "回答をコピー") }
    var editMenu: String { pick("编辑", "編集") }
    var cut: String { pick("剪切", "切り取り") }
    var copy: String { pick("复制", "コピー") }
    var paste: String { pick("粘贴", "ペースト") }
    var selectAll: String { pick("全选", "すべて選択") }

    var selfCheck: String { pick("🎙 面试前自检", "🎙 セルフチェック") }
    var interviewerAudio: String { pick("通话 App 音频", "通話アプリの音声") }
    var sttConnection: String { pick("语音识别连接", "STT 接続") }
    var deepgramKey: String { pick("Deepgram Key", "Deepgram キー") }
    var answerLLM: String { pick("回答模型", "回答 LLM") }
    var screenShareGuard: String { pick("屏幕共享保护", "画面共有ガード") }
    var notConfigured: String { pick("未设置", "未設定") }
    var uiLanguageSettings: String { pick("界面语言", "表示言語") }
    var chinese: String { pick("中文", "中国語") }
    var japanese: String { pick("日语", "日本語") }
    var startRecording: String { pick("开始录音  ⌘⇧P", "録音を開始  ⌘⇧P") }
    var stopRecording: String { pick("停止录音  ⌘⇧P", "録音を停止  ⌘⇧P") }
    var recordingStatusOn: String { pick("🔴 录音中（音频正在上传）", "🔴 録音中（音声を送信中）") }
    var recordingStatusOff: String { pick("⦿ 待机中（未录音 · 不上传）", "⦿ 待機中（未録音・送信なし）") }
    var apiKeySettings: String { pick("自备服务密钥", "自分のサービスキー") }
    var buildAnswerBank: String { pick("预生成回答", "回答を事前生成") }
    var deleteLocalData: String { pick("删除本地数据…", "ローカルデータを削除…") }
    var toggleVisibility: String { pick("显示／隐藏  ⌘⇧Space", "表示／非表示  ⌘⇧Space") }
    var quit: String { pick("退出", "終了") }
    var speechRecognitionProvider: String { pick("Deepgram（语音识别）", "Deepgram（音声認識）") }

    // MARK: STT 引擎选择
    var sttEngineLabel: String { pick("语音识别引擎", "音声認識エンジン") }
    var sttEngineHelp: String {
        pick("国内网络下推荐「Apple 本地」：离线日语识别，无需联网、无需 Deepgram Key。",
             "中国本土のネットワークでは「Apple（オンデバイス）」を推奨：オフライン日本語認識で、通信も Deepgram キーも不要です。")
    }
    var sttEngineAuto: String { pick("自动", "自動") }
    var sttEngineDeepgram: String { pick("Deepgram 云端", "Deepgram（クラウド）") }
    var sttEngineApple: String { pick("Apple 本地（离线）", "Apple（オンデバイス）") }

    var sttLocalUnavailable: String {
        pick("本地日语识别不可用：请在 系统设置 → 键盘 → 听写 中启用日语后重试。",
             "オンデバイス日本語認識が利用できません：システム設定 → キーボード → 音声入力 で日本語を有効化してから再試行してください。")
    }
    var sttNotAuthorized: String {
        pick("未授权语音识别：请在 系统设置 → 隐私与安全性 → 语音识别 中允许 NotchMeet。",
             "音声認識が許可されていません：システム設定 → プライバシーとセキュリティ → 音声認識 で NotchMeet を許可してください。")
    }
    /// 端侧日语语音模型按需下载中的进度提示（下载完成后自动开始识别）。
    func sttModelDownloading(_ percent: Int) -> String {
        pick("正在下载日语语音模型（\(percent)%）…完成后会自动开始识别。",
             "日本語の音声モデルをダウンロード中（\(percent)%）…完了後に自動で認識を開始します。")
    }

    func captureHealth(_ state: CaptureHealthState) -> String {
        switch state {
        case .notStarted: return pick("待机中（未录音）", "待機中（未録音）")
        case .noKeyOrDemo: return pick("未启动（缺少 Key／演示模式）", "未起動（キー無し／デモ）")
        case .permissionRequired: return pick("未启动，请检查系统音频权限", "未起動・システム音声の権限を確認")
        case .paused: return pick("已暂停", "一時停止中")
        case .voiceDetected: return pick("已检测到音频（最近）", "音声検出（直近）")
        case .ready: return pick("准备就绪，等待音频", "準備OK・音声待ち")
        }
    }

    func apiKeyTitle(_ provider: String) -> String { "\(provider) API Key" }
    var qwenProvider: String { pick("通义千问（DashScope）", "通義千問（DashScope）") }
    var llmChinaHint: String {
        pick("国内网络无法直连 Gemini／Claude：请配置通义千问（推荐，出字更快）或 DeepSeek Key，App 会自动优先使用可直连的服务。",
             "中国本土のネットワークでは Gemini／Claude に直接接続できません。通義千問（推奨・応答が速い）または DeepSeek のキーを設定すると、自動的に優先して使用されます。")
    }
    /// 自检菜单里 LLM 行下方的一行版警告（`llmChinaHint` 的短句，面向被墙场景）。
    var llmChinaBlockedWarning: String {
        pick("当前网络无法直连该服务：请配置通义千问或 DeepSeek Key",
             "現在のネットワークでは直接接続できません：通義千問または DeepSeek のキーを設定してください")
    }
    var apiKeyPrompt: String {
        pick("输入各自的 Key，或在任一栏粘贴激活码一次填好；留空并保存将删除。Key 会安全存入 macOS 钥匙串。",
             "各キーを入力するか、いずれかの欄にコードを貼り付けて一括設定できます。空欄で保存すると削除され、Keychain に保管されます。")
    }
    var save: String { pick("保存", "保存") }
    var cancel: String { pick("取消", "キャンセル") }
    var deleteButton: String { pick("删除", "削除") }
    var deleteConfirmTitle: String {
        pick("确认删除全部本地数据？", "すべてのローカルデータを削除しますか？")
    }
    var deleteConfirmBody: String {
        pick("将永久删除：面试原稿、答案库、简历事实，以及全部服务密钥（Deepgram · Gemini · Anthropic · DeepSeek · 通义千问）。此操作不可撤销。",
             "面接原稿、回答バンク、履歴書ファクト、およびすべてのサービスキー（Deepgram・Gemini・Anthropic・DeepSeek・通義千問）を完全に削除します。この操作は取り消せません。")
    }

    // MARK: Recording consent (data-use disclosure shown before the first recording)

    var consentTitle: String {
        pick("开始录音前，请确认数据去向", "録音を始める前に、データの送信先をご確認ください")
    }
    /// `llm` = the model the live pipeline will actually use; `sttLocal` = STT resolves to
    /// Apple on-device (国内默认，录音不上传)，so the disclosure names the true audio path;
    /// `sendsContext` reflects whether resume/script grounding is currently enabled.
    func consentBody(llm: String, sttLocal: Bool, sendsContext: Bool) -> String {
        let sttLine = sttLocal
            ? pick("· 捕获你所选通话 App 播放的声音（不使用麦克风／摄像头／屏幕），并在本机离线转成文字——录音不会上传。",
                   "· 選択した通話アプリの音声のみを取得し（マイク／カメラ／画面は不使用）、オンデバイスで文字起こしします——音声はアップロードされません。")
            : pick("· 捕获你所选通话 App 播放的声音（不使用麦克风／摄像头／屏幕），并实时上传 Deepgram 转成文字。",
                   "· 選択した通話アプリの音声のみを取得し（マイク／カメラ／画面は不使用）、リアルタイムで Deepgram に送信して文字起こしします。")
        let ctxLine = sendsContext
            ? pick("· 识别出的问题，连同你的简历要点与面试原稿，会发送给 \(llm) 生成回答。",
                   "· 認識された質問は、あなたの履歴書メモと面接原稿とともに \(llm) に送信され、回答を生成します。")
            : pick("· 识别出的问题会发送给 \(llm) 生成回答（你已关闭发送简历／原稿）。",
                   "· 認識された質問が \(llm) に送信され、回答を生成します（履歴書／原稿の送信はオフ）。")
        return pick(
            """
            录音期间：
            \(sttLine)
            \(ctxLine)
            · 服务密钥只保存在本机。

            可随时在「设置 → 隐私与数据」中关闭发送简历／原稿，或更改要捕获的通话 App。
            """,
            """
            録音中：
            \(sttLine)
            \(ctxLine)
            ・サービスキーのみ端末内に保存されます。

            「設定 → プライバシー」でいつでも履歴書／原稿の送信をオフにしたり、取得する通話アプリを変更できます。
            """)
    }
    var consentAgree: String { pick("同意并开始录音", "同意して録音を開始") }
    var consentCancel: String { pick("取消", "キャンセル") }

    // MARK: No call app detected

    var noCallAppTitle: String { pick("未检测到通话 App", "通話アプリが見つかりません") }
    var noCallAppBody: String {
        pick("NotchMeet 只捕获通话 App 的声音，而不是全部系统声音。请先打开你的通话 App（Zoom／Teams／Meet 等），或在「设置 → 隐私与数据」中指定要捕获的 App。",
             "NotchMeet はシステム全体ではなく通話アプリの音声のみを取得します。通話アプリ（Zoom／Teams／Meet など）を起動するか、「設定 → プライバシー」で取得するアプリを指定してください。")
    }
    var openPrivacySettings: String { pick("打开隐私设置", "プライバシー設定を開く") }

    // MARK: Privacy & Data panel (real data-flow disclosure + controls)

    var privacyDataFlowTitle: String { pick("数据如何流动", "データの流れ") }
    var privacyDataFlowBody: String {
        pick("录音期间，所选通话 App 的声音会实时转写：引擎为 Deepgram 时上传云端，为 Apple 本地（国内默认）时在本机离线完成、录音不上传。识别出的问题（默认连同你的简历要点与面试原稿）会发送给所选 AI（Gemini／Claude／DeepSeek／通义千问）生成回答。服务密钥与本地文件仅保存在本机，不使用麦克风、摄像头或屏幕。",
             "録音中、選択した通話アプリの音声はリアルタイムで文字起こしされます：エンジンが Deepgram の場合はクラウドに送信、Apple（オンデバイス）の場合は端末内で完結し音声は送信されません。認識された質問は（既定では履歴書メモと面接原稿とともに）選択した AI（Gemini／Claude／DeepSeek／通義千問）に送信され回答を生成します。サービスキーとローカルファイルは端末内にのみ保存され、マイク・カメラ・画面は使用しません。")
    }
    var sendContextLabel: String { pick("把简历要点与原稿发送给 AI", "履歴書メモと原稿を AI に送信") }
    var sendContextHelp: String {
        pick("开启时，回答会贴合你的经历。关闭后回答更通用：不再把简历或原稿（含其问题）发送给 AI。",
             "オンにすると回答があなたの経歴に沿います。オフにすると回答は一般的になり、履歴書や原稿（その質問を含む）を AI に送信しません。")
    }
    var captureTargetLabel: String { pick("捕获的通话 App", "取得する通話アプリ") }
    var captureTargetHelp: String {
        pick("只捕获这个 App 的声音，而不是全部系统声音。浏览器通话会捕获整个浏览器。",
             "このアプリの音声のみを取得します（システム全体ではありません）。ブラウザ通話の場合はブラウザ全体が対象になります。")
    }
    var captureTargetAuto: String { pick("自动检测通话 App", "通話アプリを自動検出") }

    // MARK: Settings window

    var openSettings: String { pick("打开设置…", "設定を開く…") }
    var secGeneral: String { pick("通用", "一般") }
    var secScripts: String { pick("面试原稿", "面接原稿") }
    var secKeys: String { pick("自备密钥", "自分のキー") }
    var secAnswer: String { pick("识别与回答", "認識と回答") }
    var secPrivacy: String { pick("隐私与数据", "プライバシー") }
    var secAbout: String { pick("关于", "概要") }

    // MARK: 通用（可自定义项）

    var launchAtLogin: String { pick("登录时自动启动", "ログイン時に自動起動") }
    var launchAtLoginHelp: String {
        pick("开机后自动在刘海待命。仅对安装在「应用程序」文件夹中的正式版生效。",
             "起動後、ノッチで自動的に待機します。「アプリケーション」フォルダにインストールした版でのみ有効です。")
    }
    var answerTextSizeLabel: String { pick("刘海回答字号", "ノッチの文字サイズ") }
    var answerTextSizeHelp: String {
        pick("面试时回答文字的大小。调大更易扫读，调小可容纳更长的回答。",
             "面接中に表示される回答文字の大きさ。大きいほど読みやすく、小さいほど長い回答が収まります。")
    }
    var answerSizeCompact: String { pick("紧凑", "コンパクト") }
    var answerSizeStandard: String { pick("标准", "標準") }
    var answerSizeLarge: String { pick("大字", "大きめ") }
    var hotkeysTitle: String { pick("快捷键", "ショートカット") }
    var hotkeyToggleVisibility: String { pick("显示／隐藏刘海", "ノッチの表示／非表示") }
    var hotkeyToggleRecording: String { pick("开始／停止录音", "録音の開始／停止") }

    // MARK: 自备密钥（高级 · BYO）

    var byoIntro: String {
        pick("高级选项：填入自己的服务密钥后将优先使用你的服务，且不消耗额度。留空则使用内置服务（按额度计）。",
             "上級者向け：ご自身のサービスキーを入力すると、そちらが優先され、残高は消費されません。空欄の場合は内蔵サービスを使用します（残高を消費）。")
    }

    var clearKey: String { pick("清除", "クリア") }
    var currentLLMLabel: String { pick("当前回答模型", "現在の回答モデル") }
    var rerunOnboarding: String { pick("重新运行新手引导", "はじめにガイドを再表示") }
    var aboutVersion: String { pick("版本", "バージョン") }
    var aboutTagline: String {
        pick("日本就活向 · 实时面试提词器", "日本の就活向け・リアルタイム面接プロンプター")
    }

    // MARK: Software update (checks GitHub Releases on demand)

    var softwareUpdate: String { pick("软件更新", "ソフトウェア・アップデート") }
    var checkForUpdates: String { pick("检查更新", "アップデートを確認") }
    var checkingForUpdates: String { pick("正在检查…", "確認中…") }
    var upToDate: String { pick("已是最新版本", "最新バージョンです") }
    func updateAvailable(_ version: String) -> String {
        pick("有新版本 v\(version)", "新バージョン v\(version)")
    }
    var downloadUpdate: String { pick("下载", "ダウンロード") }
    var updateCheckFailed: String { pick("检查失败，请重试", "確認に失敗しました") }

    // MARK: Interview-script library

    var thisInterviewScript: String { pick("本次面试原稿", "今回の面接原稿") }
    var scriptNone: String { pick("不使用原稿", "原稿を使用しない") }
    var manageScripts: String { pick("管理原稿…", "原稿を管理…") }
    var activeBadge: String { pick("启用中", "使用中") }
    var setActiveScript: String { pick("设为本次使用", "今回使用する") }
    var renameScript: String { pick("重命名", "名称変更") }
    var editScript: String { pick("编辑", "編集") }
    var addByFile: String { pick("从文件导入…", "ファイルから読み込む…") }
    var addByPaste: String { pick("粘贴新建", "貼り付けて新規作成") }
    var newScriptTitle: String { pick("新建原稿", "新規原稿") }
    var scriptNamePlaceholder: String { pick("原稿名称", "原稿の名前") }
    var back: String { pick("返回", "戻る") }
    var scriptsEmptyTitle: String { pick("还没有面试原稿", "面接原稿がありません") }
    var scriptsEmptyHint: String {
        pick("导入或粘贴你写好的面试答案：命中问题时逐字提示，未命中时作为日语回答的参考。",
             "用意した回答を読み込むか貼り付けてください。一致した質問では原稿をそのまま提示し、外れた場合は日本語回答の参考にします。")
    }
    func scriptCount(_ n: Int) -> String { pick("\(n) 个问题", "\(n) 件") }
    func scriptUpdated(_ date: String) -> String { pick("更新于 \(date)", "更新 \(date)") }
    func scriptDefaultName(_ date: String) -> String { "原稿 \(date)" }
    var scriptMigratedName: String { pick("导入的原稿", "インポート済み原稿") }
    var scriptOnboardingName: String { pick("我的原稿", "マイ原稿") }
    func deleteScriptConfirmTitle(_ name: String) -> String {
        pick("删除原稿「\(name)」？", "「\(name)」を削除しますか？")
    }
    var deleteScriptConfirmBody: String {
        pick("此原稿将被永久删除，不可撤销。", "この原稿は完全に削除され、元に戻せません。")
    }

    // MARK: 额度（分钟制钱包）

    var secWallet: String { pick("额度与充值", "残高とチャージ") }
    var creditRemainingLabel: String { pick("剩余额度", "残り時間") }
    var creditUsedLabel: String { pick("累计已用", "利用済み") }
    var creditGrantedLabel: String { pick("累计获得", "累計チャージ") }
    var creditNotMetered: String { pick("使用自己的密钥 · 不消耗额度", "ご自身のキーを使用中・残高は消費しません") }
    /// 分钟粒度的额度展示（"73 分钟" / "1時間13分" 级别的展示留给钱包页；这里通用短格式）。
    func creditMinutes(_ seconds: Int) -> String {
        let m = seconds / 60
        if seconds <= 0 { return pick("0 分钟", "0分") }
        if m == 0 { return pick("不足 1 分钟", "1分未満") }
        return pick("\(m) 分钟", "\(m)分")
    }
    /// 紧张时刻（<10 分钟）的 mm:ss 倒计时。
    func creditCountdown(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
    var creditMenuTopUp: String { pick("额度与充值…", "残高とチャージ…") }
    func creditLowAlert(_ minutes: Int) -> String {
        pick("剩余额度不足 \(minutes) 分钟", "残り時間が\(minutes)分を切りました")
    }
    var creditExhaustedTitle: String { pick("额度已用完", "残高がなくなりました") }
    var creditExhaustedBody: String {
        pick("本场录音已停止。你的准备内容都还在——充值后即可继续使用。也可以在设置里填入自己的服务密钥（不消耗额度）。",
             "録音を停止しました。準備した内容はそのまま残っています。チャージするとすぐに再開できます。設定でご自身のサービスキーを使うこともできます（残高は消費しません）。")
    }
    var creditCannotStartTitle: String { pick("额度不足，无法开始", "残高が足りないため開始できません") }
    var creditCannotStartBody: String {
        pick("当前剩余额度为 0。充值后即可开始录音；如果你有自己的服务密钥，也可以在设置中填入（不消耗额度）。",
             "残り時間が0のため録音を開始できません。チャージすればすぐに開始できます。ご自身のサービスキーをお持ちの場合は設定から入力してください（残高は消費しません）。")
    }
    var creditTopUpAction: String { pick("去充值", "チャージする") }
    var creditEnterCodeAction: String { pick("输入充值码…", "コードを入力…") }

    // MARK: 钱包页（设置 → 额度与充值）

    var walletUnitMinutes: String { pick("分钟", "分") }
    var walletRedeemTitle: String { pick("兑换充值码", "チャージコードを使う") }
    var walletRedeemPlaceholder: String { pick("粘贴你收到的充值码", "受け取ったコードを貼り付け") }
    var walletRedeemButton: String { pick("兑换", "チャージ") }
    func walletRedeemSuccess(_ minutes: Int) -> String {
        pick("已到账 +\(minutes) 分钟", "+\(minutes)分 チャージしました")
    }
    var walletRedeemKeysApplied: String { pick("服务已激活", "サービスを有効化しました") }
    var walletRedeemAlready: String { pick("这个码已经使用过了", "このコードは使用済みです") }
    var walletRedeemExpired: String { pick("这个码已过期", "このコードは有効期限切れです") }
    var walletRedeemInvalid: String {
        pick("无法识别这个码——请确认复制完整", "コードを認識できません——全体をコピーしたかご確認ください")
    }
    var walletBuyTitle: String { pick("需要更多时间？", "時間が足りませんか？") }
    var walletBuyBody: String {
        pick("获取充值码后粘贴到上方，立即到账，永不过期。", "コードを入手して上に貼り付けるだけで、すぐに反映されます。有効期限はありません。")
    }
    var walletBuyButton: String { pick("获取充值码", "コードを入手") }
    var walletGiftNote: String {
        pick("新用户见面礼：60 分钟已自动到账。", "はじめての方へ：60分ぶんを自動でプレゼント済みです。")
    }

    var prepDescription: String {
        pick("使用标题、编号、Q: 或问题句自动分隔（例如“# 自我介绍”“1. 应聘动机”）。请准备日语回答；匹配时显示原稿，未匹配时作为日语回答的参考。",
             "見出し・番号・「Q:」・質問文で自動的に区切ります（例:「# 自己紹介」「1. 志望動機」）。一致した質問では原稿をそのまま提示し、外れた場合は日本語回答の参考にします。")
    }
    var saveWithShortcut: String { pick("保存  ⌘S", "保存  ⌘S") }
    var aiNormalize: String { pick("AI 整理格式", "AIで整形") }
    var aiNormalizeHint: String {
        pick("识别到的内容较少。可以用 AI 只做分段整理——答案文本保持逐字不变。",
             "認識できた内容が少ないようです。AIで区切りだけ整えられます——回答の文面は一字も変わりません。")
    }
    var aiNormalizeFailed: String {
        pick("无法自动整理。请按“# 问题 + 回答”的格式手动分段。",
             "自動整形できませんでした。「# 質問 + 回答」の形で手動で区切ってください。")
    }
    func prepRecognition(count: Int, names: String, hasMore: Bool) -> String {
        let suffix = hasMore ? " …" : ""
        if count == 0 { return pick("已识别：0 个问题", "認識：0 件") }
        return pick("已识别：\(count) 个　\(names)\(suffix)", "認識：\(count) 件　\(names)\(suffix)")
    }
}
