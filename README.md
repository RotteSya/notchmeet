# notchmeet

> 日本就活向 · 面接サポート（macOS · 原生 Swift）

帮你准备并从容应对日语面试：先导入或构建你的回答原稿；面试时，刘海（notch）**识别面试官的提问**，显示**贴合你原稿的日语回答**，未命中再由 LLM 现场生成。无第三方依赖，纯 Apple 系统框架，macOS 14+。

- 设计与决策：[PLAN.md](PLAN.md)
- 产品落地页：<https://rottesya.github.io/notchmeet/>
- 许可：[PolyForm Noncommercial 1.0.0](LICENSE) — 源码可读、可自建作**非商业**用途；禁止商用 / 搭建竞品（详见 LICENSE）。

## 工作原理

```
面接官の声
  → 通话 App 音频 tap（Zoom / Meet / Teams 等，只抓所选 App）
  → 日语 STT（Deepgram，流式 interim + final）
  → TurnManager（判停 · 取消 · epoch）
  → Router（命中预生成答案 / 导入原稿，或现场生成）
  → LLM（Gemini / Claude）
  → 刘海に表示（原稿に沿った日语回答）
```

- **只抓所选通话 App 放出的声音**（Core Audio 进程 tap），不抓全部系统音频，也**不录你的麦克风**。
- **判停 + 取消（epoch）**：插话 / 补问 / backchannel 不误触发，新问题取消上一轮。
- **缓存优先**：命中预生成答案或导入原稿则逐字提示，未命中再现场生成；原则是「宁可不命中，绝不错命中」。

## 状态

- **Phase 0–2 + Phase 3（部分）已打通可运行**：刘海 UI、音频 → STT → 大脑 → 刘海管线、结构化事实 + 就活 prompt（文系総合職）、AnswerBank + Router、状态栏菜单 + 全局热键 + 暂停 + 一键删数据、首次启动引导。
- 默认 `pipeline = .auto`：没 key 跑 mock 演示，填了 Deepgram key 自动切 live（下次启动保持）。
- 界面可在**中文／日文**即时切换；STT、演示语音、建议回答固定使用**日语**。启动即预热 LLM 连接。
- **已用合成日语（`say -v Kyoko`）端到端冒烟通过**；完整 Phase -1 真机 gate 仍需真实通话验证（见末节）。

## 构建 & 运行

```sh
swift build              # 编译
swift run                # mock 模式跑（刘海出现并演示流式答案，无需 key / 权限）
scripts/bundle.sh        # 打成 .app（稳定 Bundle ID，TCC 权限需要）
open .build/notchmeet.app
scripts/dev-run.sh       # 开发循环：重打包 + 杀旧实例 + 重启（加 -l 前台看日志）
scripts/dmg.sh           # 出 release：签名 .dmg 到 .build/（版本取自 Info.plist）
```

> `.app` 跑的是 **release** 二进制：改完代码后 `swift build` / `swift run` 看不到变化，要 `scripts/bundle.sh` 或 `scripts/dev-run.sh` 重打包。系统音频录制权限**只有在 `.app` bundle 下**才能拿到。

## 首次启动（引导）

第一次运行会弹出引导窗口，五步走完即可使用：

1. **导入面试原稿**（可跳过）— 见下文《导入面试原稿》
2. **录音权限** — 真实触发 macOS 系统音频授权
3. **连接服务** — 粘贴**激活码**，或自带 Key（见下文《联网使用》）
4. **演示** — 在真刘海上跑一遍：朗读日语问题 → 显示日语回答
5. **完成**

之后点**刘海右侧的齿轮按钮**弹出菜单 →「打开设置」，可重新运行引导、切换语言、管理 Key 与原稿。

## 联网使用（.live）

默认 `pipeline = .auto`：**没 key 跑 mock，填了 Deepgram key 自动 live**。两种填法：

**① 试用用户 — 粘贴激活码（推荐）**
拿到形如 `nmk1.…` 的激活码，在引导第 3 步、或「设置 → API Key」**任意一个 Key 字段**粘贴，会一次性填好 Deepgram + LLM key 并自动重载到 live，无需自己申请 Key。

**② 自带 Key**
「设置 → API Key」分别填，存进 Keychain：
- `DEEPGRAM_API_KEY`（日语流式 STT，走 live 必填）
- `GEMINI_API_KEY` 或 `ANTHROPIC_API_KEY`（答案生成）

也可用同名环境变量兜底，或手动改 `AppConfig.pipeline = .live`。

**③ 分发者 — 生成激活码**
```sh
scripts/mint-code.sh <DEEPGRAM_KEY> <LLM_KEY> [gemini|claude]
```
输出一行 `nmk1.…`，私发给试用者粘贴即可。**激活码本身就是明文 Key**（本地 base64 解码，没有服务器，只是免去手填、不是加密），所以只发**限额、限时（Deepgram TTL）、一人一码**的 Key，泄露可廉价吊销。

走 live 后 `scripts/bundle.sh && open .build/notchmeet.app`，授予录音权限后重开。

## 导入面试原稿（面接原稿）

写好的答案可以导入：命中对应问题时**逐字**显示你的原稿，未命中时把原稿作为上下文喂给实时 LLM（与 facts 同等）。**离线确定性解析，不需要 API key。**

入口：引导第 1 步，或「设置 → 原稿」。选文件或直接粘贴，按约定格式书写：

```markdown
# 自己紹介
私は〇〇大学の△△です。学生時代は……

# 志望動機
貴社を志望する理由は……
```

- 支持 Markdown 标题、`Q:` / `質問:`、编号标题、`【括号标题】`、独立问题句和两列表格；题目下面的内容作为逐字答案。
- 实时显示「認識: N 件」，确认切分无误后保存。可存**多份并命名**，状态栏菜单里为**本场面试**选用哪一份。
- 存到 `knowledge/scripts.json`（`locked`，不被「答案库预生成」覆盖，随「删除本地数据」一并清除）。
- 示例见 `knowledge/script.sample.md`。

## 隐私与数据

- **只抓所选通话 App 的音频**（自动检测或在设置指定），**不录麦克风**。浏览器通话无法只抓单个标签页，会捕获整个浏览器。
- 音频实时上传 **Deepgram** 转写；识别出的问题（默认连同简历要点 / 原稿，可在「设置 → 隐私」关闭）发送给 **Gemini / Claude** 生成回答。**首次录音前弹出数据去向说明并需明确同意。**
- API Key 存 **Keychain**；激活码解码后即为 Key，同样视作机密。
- 录音状态可见、可一键暂停；**一键删除本地数据**（facts / answer_bank / scripts，位于源码运行时的 `knowledge/` 或安装后的 Application Support）。
- 首次 `.live` 若没弹权限，去「系统设置 → 隐私与安全性 → 麦克风」勾选 notchmeet（macOS 把所有音频采集都归在「麦克风」类别下，只是权限分类，**不代表录你的麦**）。

## Phase -1 真机验证（完整 gate，见 PLAN §3）

> 合成日语只证明「单链路通 + 干净音质准确 + 延迟在预算内」，**不等于过 gate**。下列需真实通话：

- **S1 音频**：三大平台（Zoom / Meet / Teams）稳定拿到面试官单路音频；设备热切换 / 睡眠唤醒自动恢复；连续 30 分钟无丢流。
- **S2 STT**：真人 / 压缩音质下的日语识别准确度 + final 延迟（已见同音词 `志望` → `死亡` 误识）。
- **S3 计时**：`[latency]` 日志按 cache · live 分列报 p50/p95/p99（冷启动单列）。
- **S4 刘海**：屏幕共享 / 多屏 / 外接屏下的可见性与几何。
- **S5 对话**：插话 / 补问 / backchannel 的现实性。
- **面试前自检**：点刘海齿轮按钮，看菜单顶部「面接官の音声 / STT 接続 / Deepgram / 回答 LLM」四项是否全 ✓。

## 目录结构

`Sources/notchmeet/` 按职责分层（详见 [PLAN.md](PLAN.md) §5）：

| 目录 | 职责 |
|---|---|
| `App/` | 启动引导、AppController（管线编排）|
| `Audio/` | 进程 tap 音频采集、判停 |
| `STT/` | Deepgram 日语流式转写、provider 抽象 |
| `Brain/` | TurnManager 状态机、Router、意图、取消（epoch）|
| `LLM/` | Gemini / Claude / FastLLM、就活 prompt、结构化事实接地 |
| `Prep/` | 原稿解析（ScriptParser）、CliRunner、预生成（PreGenerator）|
| `Core/` | Keychain、配置、计时、本地化、激活码、更新检查、本地数据 |
| `UI/` | 刘海（Notch）、引导（Onboarding）、设置（Settings）、状态栏菜单 |
