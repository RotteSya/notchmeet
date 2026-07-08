import Foundation

// MARK: - Onboarding localized copy (中 / 日), ported verbatim from the design
//
// Kept as two fully-materialized instances selected wholesale by language, rather than
// folded into `AppStrings`' per-property `pick(zh, ja)` layer: the onboarding flow has
// 50+ one-off strings, so a single zh/ja literal block per language reads better here
// than 50 interleaved pairs — and merging the two mechanisms is a risky rewrite for no
// real gain. This file just keeps that copy out of the onboarding view.

struct OBStrings {
    let welcomeT1, welcomeT2, welcomeP, welcomeBtn, welcomeFoot: String
    let k1, h1step, p1pre, p1em, p1post, lblScript, btnPickMd, btnSample, phScript, dropHint: String
    let recogPre, recogSuf: String
    let btnBack, btnSkip, btnNext: String
    let k2, h2step, p2, permLabel, permSet, permDesc, privacy, btnAllow: String
    let k3, h3step, p3pre, p3em, p3post, srcLabel, captionIdle, btnAgain: String
    let doneH, doneP, sumScriptLabel, sumPermLabel, sumLanguageLabel, sumLanguageValue, btnStart, doneFoot: String
    let demoQuestion, demoAnswer, intentTag, demoQFormat, verbatim: String
    let unitCount, skipped, permUnset: String
    // STEP 3 — connect services (API keys), and the readiness-aware「done」state.
    let kKeys, hKeys, pKeys, keyReplacePh: String
    let keyRequired, keyConnected, keyMissing, keyPrivacy, doneHpending: String
    let donePpending, sumDeepgramLabel, sumLLMLabel, btnFix, btnEnterAnyway: String
    let keyCodeLabel, keyCodePh, keyCodeHelp: String   // STEP 3 — single activation-code entry

    static func of(_ lang: UILanguage) -> OBStrings { lang == .ja ? ja : zh }

    static let zh = OBStrings(
        welcomeT1: "面试中，刘海", welcomeT2: "化作你的语言。",
        welcomeP: "实时聆听面试官的声音，将贴合你原稿与经历的回答，悄然映现在屏幕顶部的刘海上。",
        welcomeBtn: "开始", welcomeFoot: "约需 1 分钟・稍后可在设置中更改",
        k1: "STEP 1 · 面试原稿", h1step: "导入你准备好的回答",
        p1pre: "请导入日语回答。匹配到问题后，会", p1em: "原样", p1post: "呈现你的日语原稿。",
        lblScript: "原稿", btnPickMd: "选择 .md", btnSample: "示例",
        phScript: "# 自己紹介\n〇〇大学△△学部の□□と申します……\n\n# 志望動機\n貴社の「ユーザー第一」という姿勢に強く共感しています……",
        dropHint: "拖放到此处导入",
        recogPre: "已识别 ", recogSuf: " 个问题",
        btnBack: "返回", btnSkip: "跳过", btnNext: "下一步",
        k2: "STEP 2 · 访问权限", h2step: "聆听面试官的声音",
        p2: "录音期间，只捕获你所选通话 App 播放的声音（不使用麦克风）。",
        permLabel: "录制系统音频", permSet: "已允许",
        permDesc: "仅捕获你指定的通话 App 的输出音频，不触及麦克风、摄像头或屏幕。",
        privacy: "为识别问题并生成回答，录音会实时转写（云端 Deepgram，或国内默认的本机离线识别），问题与你的简历／原稿会发送给所选 AI（Gemini／Claude／DeepSeek／通义千问）。仅 API Key 保存在本机。",
        btnAllow: "允许访问",
        k3: "STEP 4 · 演示", h3step: "聆听日语，使用日语作答",
        p3pre: "播放日语问题后，可直接照念的完整日语回答会显示在", p3em: "屏幕顶部的刘海", p3post: "上。",
        srcLabel: "面试官 · 日语", captionIdle: "「志望動機について教えてください。」",
        btnAgain: "再播放一次",
        doneH: "准备就绪", doneP: "操作界面使用中文，日语面试问题与日语回答会显示在刘海中。",
        sumScriptLabel: "面试原稿", sumPermLabel: "录制系统音频",
        sumLanguageLabel: "语言", sumLanguageValue: "界面：中文 · 面试与回答：日语",
        btnStart: "开始使用 NotchMeet", doneFoot: "提示：⌘⇧Space 可切换显示／隐藏",
        demoQuestion: "志望動機について教えてください。",
        demoAnswer: "私は、貴社の「ユーザー第一」という姿勢に強く共感しています。インターンで培ったデータ分析の経験を活かし、利用者の声を丁寧に捉えながらプロダクト改善に貢献したいと考えています。",
        intentTag: "志望動機", demoQFormat: "%@について教えてください。", verbatim: "日语原稿",
        unitCount: "个", skipped: "已跳过", permUnset: "未设置",
        kKeys: "STEP 3 · 连接服务", hKeys: "粘贴激活码即可使用",
        pKeys: "粘贴我们提供的激活码，无需自己准备 API Key。自带 Key 的用户可在「设置」中手动填写。",
        keyReplacePh: "已连接 · 粘贴新 Key 可替换",
        keyRequired: "必填", keyConnected: "已连接", keyMissing: "待设置 · 必填",
        keyPrivacy: "Key 仅存于本机钥匙串，绝不上传服务器。",
        doneHpending: "还差最后一步", donePpending: "完成下面标记「待设置」的项目，就能开始使用。",
        sumDeepgramLabel: "语音识别 · Deepgram", sumLLMLabel: "回答生成 · AI",
        btnFix: "去补齐设置", btnEnterAnyway: "仍然进入",
        keyCodeLabel: "激活码", keyCodePh: "粘贴激活码", keyCodeHelp: "试用码由我们提供 · 自带 Key 请在设置中填写"
    )

    static let ja = OBStrings(
        welcomeT1: "面接中、ノッチが", welcomeT2: "あなたの言葉になる。",
        welcomeP: "面接官の声をリアルタイムで聞き取り、あなたの原稿と経歴に沿った答えを、画面上部のノッチにそっと映し出します。",
        welcomeBtn: "はじめる", welcomeFoot: "所要時間 約1分・あとから設定で変更できます",
        k1: "STEP 1 / 面接原稿", h1step: "用意した答えを読み込む",
        p1pre: "見出しで質問を区切った原稿を貼り付けると、一致した質問では原稿を", p1em: "そのまま", p1post: "提示します。",
        lblScript: "原稿", btnPickMd: ".md を選択", btnSample: "サンプル",
        phScript: "# 自己紹介\n〇〇大学△△学部の□□と申します……\n\n# 志望動機\n貴社の「ユーザー第一」という姿勢に……",
        dropHint: "ここにドロップして読み込む",
        recogPre: "", recogSuf: " 件の質問を認識しました",
        btnBack: "戻る", btnSkip: "スキップ", btnNext: "次へ",
        k2: "STEP 2 / アクセス許可", h2step: "面接官の声を聞き取る",
        p2: "録音中、選択した通話アプリから出る音声のみを取得します（マイクは使いません）。",
        permLabel: "システム音声の録音", permSet: "許可済み",
        permDesc: "指定した通話アプリの出力音声のみを取得します。マイク・カメラ・画面には触れません。",
        privacy: "質問の認識と回答生成のため、音声はリアルタイムで文字起こしされ（Deepgram またはオンデバイス認識）、質問とあなたの履歴書／原稿は選択した AI（Gemini／Claude／DeepSeek／通義千問）に送信されます。API キーのみ端末内に保存されます。",
        btnAllow: "アクセスを許可",
        k3: "STEP 4 / デモ", h3step: "聞いて、答える。試してみる",
        p3pre: "再生すると面接官の質問が流れます。", p3em: "画面上部のノッチ", p3post: "に、そのまま読める回答文が現れます。",
        srcLabel: "面接官 · Zoom", captionIdle: "「志望動機について教えてください。」",
        btnAgain: "もう一度",
        doneH: "準備が整いました", doneP: "面接が始まったら、通話アプリを開くだけ。ノッチが静かに待機しています。",
        sumScriptLabel: "面接原稿", sumPermLabel: "システム音声の録音",
        sumLanguageLabel: "言語", sumLanguageValue: "画面：日本語・面接と回答：日本語",
        btnStart: "NotchMeet を始める", doneFoot: "ヒント: ⌘⇧Space で表示／非表示を切り替えられます",
        demoQuestion: "志望動機について教えてください。",
        demoAnswer: "私は、貴社の「ユーザー第一」という姿勢に強く共感しています。インターンで培ったデータ分析の経験を活かし、利用者の声を丁寧に捉えながらプロダクト改善に貢献したいと考えています。",
        intentTag: "志望動機", demoQFormat: "%@について教えてください。", verbatim: "原稿どおり",
        unitCount: "件", skipped: "スキップ", permUnset: "未設定",
        kKeys: "STEP 3 / 接続", hKeys: "コードを貼り付けるだけ",
        pKeys: "お渡しするアクティベーションコードを貼り付けるだけ。API キーの用意は不要です。自分のキーを使う場合は設定から。",
        keyReplacePh: "接続済み · 新しいキーで置き換え可",
        keyRequired: "必須", keyConnected: "接続済み", keyMissing: "未設定 · 必須",
        keyPrivacy: "キーは端末の Keychain にのみ保存され、送信されません。",
        doneHpending: "あと一歩で完了", donePpending: "下の「未設定」の項目を整えると、すぐに使えます。",
        sumDeepgramLabel: "音声認識 · Deepgram", sumLLMLabel: "回答生成 · AI",
        btnFix: "設定を完了する", btnEnterAnyway: "そのまま開始",
        keyCodeLabel: "アクティベーションコード", keyCodePh: "コードを貼り付け", keyCodeHelp: "試用コードはこちらでお渡しします · 自分のキーは設定から"
    )
}
