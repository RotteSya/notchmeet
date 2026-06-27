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
        case .apiKeyMissing: return pick("尚未设置 API Key（点击右侧设置）", "APIキー未設定（右側の設定から追加）")
        case .autoStopped: return pick("因长时间无发言已自动停止录音", "発言がないため録音を自動停止")
        case .bankGenerating: return pick("正在预生成回答…", "回答を事前生成中…")
        case .startupError: return pick("启动失败", "起動エラー")
        case .generationError: return pick("回答生成失败", "回答生成エラー")
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
        case .apiKeyMissing: return pick("需要设置 API Key", "APIキーが必要です")
        case .autoStopped: return pick("已自动停止", "自動停止しました")
        case .bankGenerating: return pick("准备回答中", "回答を準備中")
        case .startupError, .generationError: return pick("需要处理", "確認が必要です")
        }
    }

    func generationError(_ detail: String) -> String {
        pick("（回答生成失败：\(detail)）", "（回答生成エラー：\(detail)）")
    }

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
    var apiKeySettings: String { pick("API Key 设置", "API キー設定") }
    var buildAnswerBank: String { pick("预生成回答", "回答を事前生成") }
    var deleteLocalData: String { pick("删除本地数据…", "ローカルデータを削除…") }
    var toggleVisibility: String { pick("显示／隐藏  ⌘⇧Space", "表示／非表示  ⌘⇧Space") }
    var quit: String { pick("退出", "終了") }
    var speechRecognitionProvider: String { pick("Deepgram（语音识别）", "Deepgram（音声認識）") }

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
    var apiKeyPrompt: String {
        pick("输入 Key；留空并保存将删除。Key 会安全存入 macOS 钥匙串。",
             "キーを入力してください。空欄で保存すると削除され、Keychain に保管されます。")
    }
    var save: String { pick("保存", "保存") }
    var cancel: String { pick("取消", "キャンセル") }
    var deleteButton: String { pick("删除", "削除") }
    var deleteConfirmTitle: String {
        pick("确认删除全部本地数据？", "すべてのローカルデータを削除しますか？")
    }
    var deleteConfirmBody: String {
        pick("将永久删除：面试原稿、答案库、简历事实，以及全部 API Key（Deepgram · Gemini · Anthropic）。此操作不可撤销。",
             "面接原稿、回答バンク、履歴書ファクト、およびすべての API キー（Deepgram・Gemini・Anthropic）を完全に削除します。この操作は取り消せません。")
    }

    // MARK: Recording consent (data-use disclosure shown before the first recording)

    var consentTitle: String {
        pick("开始录音前，请确认数据去向", "録音を始める前に、データの送信先をご確認ください")
    }
    /// `llm` = the model the live pipeline will actually use (Gemini/Claude); `sendsContext`
    /// reflects whether resume/script grounding is currently enabled.
    func consentBody(llm: String, sendsContext: Bool) -> String {
        let ctxLine = sendsContext
            ? pick("· 识别出的问题，连同你的简历要点与面试原稿，会发送给 \(llm) 生成回答。",
                   "· 認識された質問は、あなたの履歴書メモと面接原稿とともに \(llm) に送信され、回答を生成します。")
            : pick("· 识别出的问题会发送给 \(llm) 生成回答（你已关闭发送简历／原稿）。",
                   "· 認識された質問が \(llm) に送信され、回答を生成します（履歴書／原稿の送信はオフ）。")
        return pick(
            """
            录音期间：
            · 捕获你所选通话 App 播放的声音（不使用麦克风／摄像头／屏幕），并实时上传 Deepgram 转成文字。
            \(ctxLine)
            · 仅 API Key 保存在本机。

            可随时在「设置 → 隐私与数据」中关闭发送简历／原稿，或更改要捕获的通话 App。
            """,
            """
            録音中：
            · 選択した通話アプリの音声のみを取得し（マイク／カメラ／画面は不使用）、リアルタイムで Deepgram に送信して文字起こしします。
            \(ctxLine)
            · API キーのみ端末内に保存されます。

            「設定 → プライバシー」でいつでも履歴書／原稿の送信をオフにしたり、取得する通話アプリを変更できます。
            """)
    }
    var consentAgree: String { pick("同意并开始录音", "同意して録音を開始") }
    var consentCancel: String { pick("取消", "キャンセル") }

    // MARK: No call app detected

    var noCallAppTitle: String { pick("未检测到通话 App", "通話アプリが見つかりません") }
    var noCallAppBody: String {
        pick("notchmeet 只捕获通话 App 的声音，而不是全部系统声音。请先打开你的通话 App（Zoom／Teams／Meet 等），或在「设置 → 隐私与数据」中指定要捕获的 App。",
             "notchmeet はシステム全体ではなく通話アプリの音声のみを取得します。通話アプリ（Zoom／Teams／Meet など）を起動するか、「設定 → プライバシー」で取得するアプリを指定してください。")
    }
    var openPrivacySettings: String { pick("打开隐私设置", "プライバシー設定を開く") }

    // MARK: Privacy & Data panel (real data-flow disclosure + controls)

    var privacyDataFlowTitle: String { pick("数据如何流动", "データの流れ") }
    var privacyDataFlowBody: String {
        pick("录音期间，所选通话 App 的声音会实时上传 Deepgram 转写；识别出的问题（默认连同你的简历要点与面试原稿）会发送给所选 AI（Gemini 或 Claude）生成回答。API Key 与本地文件仅保存在本机，不使用麦克风、摄像头或屏幕。",
             "録音中、選択した通話アプリの音声はリアルタイムで Deepgram に送信され文字起こしされます。認識された質問は（既定では履歴書メモと面接原稿とともに）選択した AI（Gemini または Claude）に送信され回答を生成します。API キーとローカルファイルは端末内にのみ保存され、マイク・カメラ・画面は使用しません。")
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
    var secKeys: String { pick("API 密钥", "API キー") }
    var secAnswer: String { pick("回答引擎", "回答エンジン") }
    var secPrivacy: String { pick("隐私与数据", "プライバシー") }
    var secAbout: String { pick("关于", "概要") }

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

    var prepDescription: String {
        pick("使用标题、编号、Q: 或问题句自动分隔（例如“# 自我介绍”“1. 应聘动机”）。请准备日语回答；匹配时显示原稿，未匹配时作为日语回答的参考。",
             "見出し・番号・「Q:」・質問文で自動的に区切ります（例:「# 自己紹介」「1. 志望動機」）。一致した質問では原稿をそのまま提示し、外れた場合は日本語回答の参考にします。")
    }
    var saveWithShortcut: String { pick("保存  ⌘S", "保存  ⌘S") }
    func prepRecognition(count: Int, names: String, hasMore: Bool) -> String {
        let suffix = hasMore ? " …" : ""
        if count == 0 { return pick("已识别：0 个问题", "認識：0 件") }
        return pick("已识别：\(count) 个　\(names)\(suffix)", "認識：\(count) 件　\(names)\(suffix)")
    }
}
