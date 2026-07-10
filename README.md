# NotchMeet

> 日本就活向 · 面接サポート（macOS · 原生 Swift）

帮你准备并从容应对日语面试：先导入或构建你的回答原稿；面试时，刘海（notch）**识别面试官的提问**，显示**贴合你原稿的日语回答**，未命中再由 LLM 现场生成。无第三方依赖，纯 Apple 系统框架，macOS 14+。

- 设计与决策：[PLAN.md](PLAN.md)
- 产品落地页：<https://rottesya.github.io/notchmeet/>
- 许可：[PolyForm Noncommercial 1.0.0](LICENSE) — 源码可读、可自建作**非商业**用途；禁止商用 / 搭建竞品（详见 LICENSE）。

## 工作原理

```
面接官の声
  → 通话 App 音频 tap（Zoom / Meet / Teams 等，只抓所选 App）
  → 日语 STT（Deepgram，流式 interim + final；国内自动切 Apple 端侧离线识别）
  → TurnManager（判停 · 取消 · epoch）
  → Router（命中预生成答案 / 导入原稿，或现场生成）
  → LLM（Gemini / Claude；国内优先 通义千问 / DeepSeek，可直连）
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
scripts/dev-run.sh       # 开发循环：打成 .app（稳定 Bundle ID，TCC 权限需要）+ 杀旧实例 + 重启（加 -l 前台看日志）
open .build/NotchMeet.app
scripts/release.sh       # 出对外可分发 release：Developer ID 签名 + 公证 + 装订 .dmg 到 .build/（版本取自 Info.plist）
```

> `.app` 跑的是 **release** 二进制：改完代码后 `swift build` / `swift run` 看不到变化，要 `scripts/dev-run.sh` 重打包。系统音频录制权限**只有在 `.app` bundle 下**才能拿到。

## 首次启动（引导）

第一次运行会弹出引导窗口，七步走完即可使用，全程零技术名词：

1. **欢迎** — 品牌页，中／日界面语言即时切换
2. **工作原理** — 三拍动画：面试官提问 → 对准你的原稿 → 浮现在刘海
3. **导入面试原稿**（可跳过）— 见下文《导入面试原稿》
4. **录音权限** — 真实触发 macOS 系统音频授权
5. **见面礼／激活** — 出厂含内置服务的商业构建：60 分钟额度到账动效；否则粘贴**激活码**（充值码 `nmc1.` 或设置码 `nmk1.` 均可）
6. **演示** — 在真刘海上跑一遍：朗读日语问题 → 显示日语回答
7. **完成** — 诚实就绪总结（语音识别 / 回答生成 / 可用额度 / 权限逐项核对，未就绪会带你回去补齐）

之后点**刘海右侧的齿轮按钮**弹出菜单 →「打开设置」，可查看**额度与充值**、重新运行引导、切换语言、管理密钥与原稿。

## 商业化（额度制）

- **计费单位＝分钟额度**。新用户见面礼 **60 分钟**（仅出厂含内置服务的构建自动发放，一次性，Keychain 记账、重装不重发也不清零）。
- **计量规则**：只有本场会话用到**受管密钥**（出厂内置或激活码带入）才按录音秒数扣减；**自备密钥（BYO）或纯本地识别永不扣费**。
- **体验闭环**：刘海计量中常显剩余额度（≤10 分钟转琥珀色 mm:ss 倒计时、≤3 分钟转红），剩 10 / 3 分钟各轻提醒一次；归零自动停止录音并引导充值（准备的内容全部保留）。
- **充值码 `nmc1.…`**：Ed25519 **签名票据**（改一字节即失效），负载＝分钟数 + 可选服务 Key + 可选有效期；本机记录已兑 id 防重复兑换。在「设置 → 额度与充值」或引导第 5 步粘贴即到账。
- **账本**存独立 Keychain service（`com.notchmeet.credit`）——「删除本地数据」清 Key 不清余额。

**开发者工具链（`scripts/nmtool.swift`，私钥永不进 App）**：

```sh
swift scripts/nmtool.swift gen-keys                                  # 一次性：生成 Ed25519 签名密钥对（私钥 ~/.notchmeet/，chmod 600，务必备份）
swift scripts/nmtool.swift mint --minutes 120 --count 10             # 铸充值码；可加 --keys keys.json（随码带 Key）--exp 2027-12-31
swift scripts/nmtool.swift provision --keys keys.json --gift 3600    # 生成出厂配置 → ~/.notchmeet/provisioning.nmp
swift scripts/nmtool.swift decode <nmc1.…|nmp1.…|nmk1.…>             # 调试：解出负载明文
```

`scripts/release.sh` 检测到 `~/.notchmeet/provisioning.nmp` 时自动打进 .app（内置服务 Key + 验签公钥 + 购买页 URL + 赠礼秒数，XOR 混淆存放）——用户装完即用、额度计量生效；没有该文件则构建 BYO 版。

## 联网使用（.live）

默认 `pipeline = .auto`：**解析到可用的识别引擎即自动 live**（出厂内置 Key、激活码、自备 Key、国内 Apple 端侧识别皆可）。三种供给：

**① 商业构建（推荐）** — 出厂内置受管服务，装好即用，见上节《商业化》。

**② 自带密钥（高级，不消耗额度）**
「设置 → 自备密钥」分别填，存进 Keychain：
- `DEEPGRAM_API_KEY`（日语流式 STT；国内网络默认走 Apple 端侧识别，可不填）
- `GEMINI_API_KEY` 或 `ANTHROPIC_API_KEY`（答案生成）
- `DASHSCOPE_API_KEY`（通义千问，国内推荐——TTFT 稳定）或 `DEEPSEEK_API_KEY`——**国内网络必填其一**：Gemini/Claude 在大陆不可直连，App 检测到国内环境会自动优先使用可直连的域内服务

也可用同名环境变量兜底，或手动改 `AppConfig.pipeline = .live`。

**③ 运维设置码（`scripts/mint-code.sh`，遗留通道）**
```sh
scripts/mint-code.sh <DEEPGRAM_KEY|-> <LLM_KEY> [gemini|claude|deepseek|qwen]   # 国内码：`-` 跳过 Deepgram，deepseek/qwen 作 LLM
```
输出一行 `nmk1.…`（**明文 Key 的 base64，不入账、无签名**），只发**限额、限时、一人一码**的 Key。日常发码请改用 `nmtool mint`（签名 + 入账）。

走 live 后 `scripts/dev-run.sh`（重打包并重启），授予录音权限后重开。

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
- 音频实时转写：Deepgram 引擎上传云端，Apple 端侧引擎（国内默认）在本机离线完成、**录音不上传**；识别出的问题（默认连同简历要点 / 原稿，可在「设置 → 隐私」关闭）发送给所选 AI（**Gemini / Claude / DeepSeek / 通义千问**）生成回答。**首次录音前弹出数据去向说明并需明确同意。**
- API Key 存 **Keychain**；激活码解码后即为 Key，同样视作机密。
- 录音状态可见、可一键暂停；**一键删除本地数据**（facts / answer_bank / scripts，位于源码运行时的 `knowledge/` 或安装后的 Application Support）。
- 首次 `.live` 若没弹权限，去「系统设置 → 隐私与安全性 → 麦克风」勾选 NotchMeet（macOS 把所有音频采集都归在「麦克风」类别下，只是权限分类，**不代表录你的麦**）。

## Phase -1 真机验证（完整 gate，见 PLAN §3）

> 合成日语只证明「单链路通 + 干净音质准确 + 延迟在预算内」，**不等于过 gate**。下列需真实通话：

- **S1 音频**：三大平台（Zoom / Meet / Teams）稳定拿到面试官单路音频；设备热切换 / 睡眠唤醒自动恢复；连续 30 分钟无丢流。
- **S2 STT**：真人 / 压缩音质下的日语识别准确度 + final 延迟（已见同音词 `志望` → `死亡` 误识）。
- **S3 计时**：`[latency]` 日志按 cache · live 分列报 p50/p95/p99（冷启动单列）。
- **S4 刘海**：屏幕共享 / 多屏 / 外接屏下的可见性与几何。
- **S5 对话**：插话 / 补问 / backchannel 的现实性。
- **面试前自检**：点刘海齿轮按钮，看菜单顶部「面接官の音声 / STT 接続 / Deepgram / 回答 LLM」四项是否全 ✓。

## 目录结构

`Sources/NotchMeet/` 按职责分层（详见 [PLAN.md](PLAN.md) §5）：

| 目录 | 职责 |
|---|---|
| `App/` | 启动引导、AppController（管线编排）|
| `Audio/` | 进程 tap 音频采集、判停 |
| `STT/` | Deepgram 日语流式转写、Apple 端侧离线识别（国内）、provider 抽象 |
| `Brain/` | TurnManager 状态机、Router、意图、取消（epoch）|
| `LLM/` | Gemini / Claude / DeepSeek / 通义千问 / FastLLM、就活 prompt、结构化事实接地 |
| `Prep/` | 原稿解析（ScriptParser）、CliRunner、预生成（PreGenerator）|
| `Core/` | Keychain、配置、计时、本地化、激活码、更新检查、本地数据 |
| `UI/` | 刘海（Notch）、引导（Onboarding）、设置（Settings）、状态栏菜单 |
