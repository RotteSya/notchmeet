# notchmeet

日本就活向 · 实时面试提词器（macOS, native Swift）。监听面试官语音 → 日语 STT →
简历/知识库喂 LLM → 可直接照念的日语回答 → **macOS 刘海（notch）**。设计见 [PLAN.md](PLAN.md)。

> **许可：** [MIT](LICENSE)。客户端为 MIT 开源。

## 状态

- **Phase 0–2 + Phase 3（部分）已打通可运行**：刘海 UI + 管线（音频 tap → 日语 STT → TurnManager → LLM → notch）、结构化事实 + 就活 prompt + 文系総合職、AnswerBank + Router（命中缓存/现场生成并行 commit）、状态栏面板 + 热键 + 暂停 + 一键删数据。
- **面接原稿のインポート**：导入自己写好的面试稿，命中问题时逐字提示、未命中时作为生成依据（见下）。
- **界面与面试语言分离**：操作界面可在中文／日文间即时切换；STT、演示语音和建议回答固定使用日语。
- **启动即预热 LLM 连接** + **面试前自检**：刘海右侧设置按钮的菜单显示「面接官の音声 / STT 接続 / Deepgram / 回答 LLM」四项就绪状态。
- **§4 忠实计时**：`[latency]` 日志含判停延迟、缓存/现场分列、p50/p95/p99、冷启动单列。
- 默认 `AppConfig.pipeline = .auto`：没 key 跑 mock 演示，填了 Deepgram key 自动切 live。
- **S1/S2 已用合成日语冒烟测通过**；完整 Phase -1 gate 仍需真机真实通话（见末节）。

## 构建 & 运行

```sh
swift build              # 编译
swift run                # 跑（mock 模式：刘海出现并演示流式答案）
scripts/bundle.sh        # 打成 .app（带稳定 Bundle ID，TCC 权限需要）
open .build/notchmeet.app
scripts/dev-run.sh       # 改完代码用这个：重打包 + 杀旧实例 + 重启（加 -l 前台看日志）
scripts/dmg.sh           # 出 release：打签名 .dmg 到 .build/（版本取自 Info.plist）
```

> `.app` 跑的是 **release** 二进制，所以改完代码后 `swift build` 看不到变化——要 `scripts/bundle.sh` 或 `scripts/dev-run.sh` 重打包。
>
> 实时音频采集走 **Core Audio 进程 tap**：只抓你所选**通话 App**（Zoom/Teams/Meet 等，自动检测或在设置中指定）放出来的声音，**不是全部系统音频**，也**不录你自己的麦克风**。这段音频会实时上传 **Deepgram** 转写；识别出的问题（默认连同简历要点/原稿，可在「设置 → 隐私与数据」关闭）发送给 **Gemini/Claude** 生成回答。浏览器通话无法只抓单个标签页，会捕获整个浏览器。首次录音前会弹出数据去向说明并需明确同意。
> 只有在 **.app bundle** 下才能拿到系统音频录制权限；首次运行 `.live` 时 macOS 会请求，若没弹去「系统设置 → 隐私与安全性 → 麦克风」勾选 notchmeet（macOS 把所有音频采集都归在「麦克风」类别下，只是权限分类，不代表录你的麦）。

## 切到实时（.live）

默认 `pipeline = .auto`：**没 key 跑 mock，填了 Deepgram key 自动切 live**（并在下次启动保持）。

**填 key（推荐）**：刘海右侧设置按钮 →「API Key 设置／API キー設定」→ Deepgram / Gemini / Anthropic，点一下弹安全输入框，存进 Keychain，填完自动重载到 live。
- `DEEPGRAM_API_KEY`（日语流式 STT，必填以走 live）
- `GEMINI_API_KEY` 或 `ANTHROPIC_API_KEY`（答案生成）

也可用环境变量（env 兜底）或手动改 `AppConfig.pipeline = .live`。
走 live 时 `scripts/bundle.sh && open .build/notchmeet.app`，授予音频录制权限后重开。
菜单还提供：界面语言、暂停/恢复、**导入面试原稿／面接原稿をインポート…**、回答预生成、一键删本地数据，以及顶部**面试前自检**四项。

## 导入面试稿（面接原稿のインポート）

已经写好的面试答案可以导入：命中对应问题时**逐字**显示你的原稿，没命中时把原稿作为上下文喂给实时 LLM（与 facts 同等）。离线确定性解析，**不需要 API key**。

刘海右侧设置按钮 →「面接原稿をインポート…」打开窗口，选文件或直接粘贴，按约定格式书写：

```markdown
# 自己紹介
私は〇〇大学の△△です。学生時代は……

# 志望動機
貴社を志望する理由は……
```

- 支持 Markdown 标题、`Q:` / `質問:`、编号标题、`【括号标题】`、独立问题句和两列表格；题目下面的内容作为逐字答案。
- 窗口实时显示「認識: N 件」，确认切分无误后按 **⌘S / 保存**。
- 存到 `knowledge/script.json`（`locked: true`，不被「答案库を事前生成」覆盖；「ローカルデータを削除」会一并清除）。
- 示例见 [knowledge/script.sample.md](knowledge/script.sample.md)。

## Phase -1 验证（完整 gate 需真机真实通话，见 PLAN §3）

> 已用合成日语（`say -v Kyoko`）冒烟跑通 S1/S2 单链路；下列为真机真实通话下的完整验收。

- **S1 音频**：`.live` 下放一段 Zoom/Meet 真实通话，确认刘海随面试官说话出字；测设备热切换/睡眠唤醒能否自动恢复（自动重建 tap 尚未做）。
- **S2 STT**：真人/压缩音质下的日语识别准确度 + final 延迟。
- **S3 计时**：Console 里 `[latency]` 日志含 `endpoint`（判停）/ `gen` / first_readable / total，按 cache·live 分列报 p50/p95/p99（冷启动单列）。
- **S4 刘海**：屏幕共享/多屏/外接屏下的可见性与几何。
- **面试前**：点刘海右侧设置按钮，看自检四项是否全 ✓。

## 目录

见 PLAN.md §6。`Sources/notchmeet/` 下按 App / Audio / STT / LLM / Brain / Knowledge / Prep / UI / Core 分层。
