import Foundation

/// 备战工作台的全部文案（中/日）。与 OBStrings 同款先例：面积大的界面文案独立成表，
/// 不再往 Localization.swift 里堆。
struct WBStrings {
    let language: UILanguage
    static var current: WBStrings { WBStrings(language: AppLanguageStore.shared.language) }
    private func pick(_ zh: String, _ ja: String) -> String { language == .zh ? zh : ja }

    // 窗口与栏
    var windowTitle: String { pick("备战工作台", "準備ワークベンチ") }
    var targetsHeader: String { pick("面试目标", "面接ターゲット") }
    var newTarget: String { pick("新建目标", "ターゲットを追加") }
    var newTargetDefaultName: String { pick("新目标", "新規ターゲット") }
    var globalAmmo: String { pick("通用弹药库", "共通ライブラリ") }
    var deleteTarget: String { pick("删除此目标", "このターゲットを削除") }
    var deleteTargetConfirm: String {
        pick("删除后该公司的绑定与偏好设置将一并移除（事实与稿件本体不受影响）。",
             "削除するとこの会社の紐付けと偏重設定も消えます（事実と原稿本体は残ります）。")
    }

    // 目标信息
    var companyPlaceholder: String { pick("公司名", "会社名") }
    var rolePlaceholder: String { pick("岗位（可选）", "職種（任意）") }
    var stagePlaceholder: String { pick("阶段，如：一面（可选）", "段階（例：一次面接）") }
    var jdLabel: String { pick("职位描述（JD）", "求人票（JD）") }
    var jdHelp: String {
        pick("只用于语音识别热词与画像定向，不做深度分析；留空完全没问题。",
             "音声認識のキーワードと文脈の絞り込みだけに使います。空欄でも問題ありません。")
    }
    var scriptBinding: String { pick("本目标用稿", "このターゲットの原稿") }
    var scriptNone: String { pick("不用稿", "原稿なし") }
    func scriptEntryCount(_ n: Int) -> String { pick("\(n) 条", "\(n) 件") }

    // 装填与解析反馈
    var loadAmmo: String { pick("装填弹药（简历 / 面试稿）…", "資料を取り込む（履歴書 / 原稿）…") }
    var ammoIntro: String {
        pick("导入简历或面试稿，AI 解析出的每条弹药都带原文出处，逐条确认后进入备战。",
             "履歴書か原稿を取り込むと、抽出された各項目に原文の出典が付きます。1 件ずつ確認して備えましょう。")
    }
    func parsingLocal(_ blocks: Int) -> String {
        pick("已读到 \(blocks) 个区块，正在解析…", "\(blocks) 個のブロックを読み取り、解析中…")
    }
    var parsingExtract: String { pick("正在读你的经历，弹药逐条入库…", "経歴を読み取り、項目を追加しています…") }
    func parsedAsScript(_ n: Int) -> String {
        pick("识别为面试稿：\(n) 条问答已入稿库并绑定本目标",
             "面接原稿として認識：\(n) 件を保存し、このターゲットに紐付けました")
    }
    func extracted(_ exp: Int, _ mot: Int, _ notes: Int, uncertain: Int) -> String {
        let base = pick("识别出 \(exp) 段经历 · \(mot) 条动机 · \(notes) 条备忘",
                        "経験 \(exp) 件・志望動機 \(mot) 件・メモ \(notes) 件を抽出")
        guard uncertain > 0 else { return base + pick("，请逐条确认", "。1 件ずつご確認ください") }
        return base + pick("，其中 \(uncertain) 项待你补全确认", "。うち \(uncertain) 件は要確認です")
    }
    var parseLLMOff: String {
        pick("未启用 AI 抽取（隐私开关关闭或未配置服务）——已按区块整理，请在下方手动补全。",
             "AI 抽出は無効です（プライバシー設定または未設定）。ブロック単位で整理しました。手動で補完してください。")
    }
    var parseNoCredit: String {
        pick("额度不足，未走 AI 抽取——已按区块整理；充值后可重新装填。",
             "残高不足のため AI 抽出は行われませんでした。ブロック単位で整理済み。チャージ後に再取り込みできます。")
    }
    var extractFailed: String {
        pick("自动抽取没能完成——已按区块整理，请手动补全，或稍后重试。",
             "自動抽出に失敗しました。ブロック単位で整理済み。手動で補完するか、後で再試行してください。")
    }
    var chargeNote: String {
        pick("使用内置服务解析一份简历计 1 分钟额度；自备密钥不扣费。",
             "内蔵サービスでの解析は 1 回につき 1 分の残高を使います。自前キーは無料。")
    }

    // 弹药面板
    var experiencesHeader: String { pick("经历弹药", "経験") }
    var motivationsHeader: String { pick("志望与动机", "志望・動機") }
    var notesHeader: String { pick("备忘", "メモ") }
    var emptyAmmo: String {
        pick("弹药库还是空的。装填一份简历，或在设置 → 简历事实里手动填写。",
             "まだ空です。履歴書を取り込むか、設定 →「履歴書の事実」で手入力してください。")
    }
    var confirm: String { pick("确认", "確認") }
    var confirmed: String { pick("已确认", "確認済み") }
    var draft: String { pick("草稿", "下書き") }
    var uncertainBadge: String { pick("AI 不确定，请补全", "AI が不確か・要確認") }
    func sourceFrom(_ name: String) -> String { pick("出处 · \(name)", "出典 · \(name)") }
    var pinForTarget: String { pick("本目标必带", "必ず使う") }
    var excludeForTarget: String { pick("本目标不带", "使わない") }
    var editInSettings: String { pick("在设置中编辑全文", "設定で全文を編集") }
    var deleteFact: String { pick("删除", "削除") }

    // 战备度
    var readinessHeader: String { pick("战备度", "準備状況") }
    func ammoProgress(_ confirmed: Int, _ total: Int) -> String {
        pick("弹药确认 \(confirmed)/\(total)", "資料確認 \(confirmed)/\(total)")
    }
    var checkInterviewLanguage: String { pick("面试语言", "面接の言語") }
    var checkStt: String { pick("语音识别", "音声認識") }
    var checkLLM: String { pick("回答生成", "回答生成") }
    var checkGuard: String { pick("屏幕共享保护", "画面共有ガード") }
    var checkCredit: String { pick("剩余额度", "残り時間") }
    var checkScript: String { pick("稿件绑定", "原稿の紐付け") }
    var checkBank: String { pick("预生成答案库", "事前生成ライブラリ") }
    func bankCount(_ n: Int) -> String { pick("\(n) 题", "\(n) 件") }
    var bankBuild: String { pick("预生成", "事前生成") }
    var notConfigured: String { pick("未配置", "未設定") }
    var mockMode: String { pick("演示模式", "デモモード") }
    var prepare: String { pick("准备面试", "面接に備える") }
    var prepareHintNoTarget: String {
        pick("先在左侧选择一个面试目标", "左でターゲットを選んでください")
    }
    var prepareHintReady: String {
        pick("武装画像、预热连接，并收入刘海待命", "コンテキストを準備し、ノッチに収納して待機します")
    }
}
