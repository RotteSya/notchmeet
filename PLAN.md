# NotchMeet — 开发计划

> 日本就活向 · 实时面试提词器（AI Interview Prompter）
> 监听面试官语音 → STT → 简历/知识库喂 LLM → 可直接照念的日语回答 → macOS 刘海（notch）交互区

---

## 0. 文档状态（重要）

本文档区分两类内容，**不再把技术可行性赌注当成已锁定结论**：

- **§1 已锁定** = 产品/策略选择（不依赖未验证的技术）。
- **§2 待验证假设** = 技术可行性赌注，**Phase -1 通过前不锁定**。
- **§3 Phase -1** = 先做的技术真实性验证 + 通过门槛。门槛过了，才允许锁 §2。

---

## 1. 已锁定（范围 / 策略）

| 维度 | 决定 |
|---|---|
| 场景 | **仅 Web 面接**（Zoom / Meet / Teams + 就活ツール） |
| 输入 | **纯音频**，无屏幕识别 / OCR / 视觉 |
| 覆盖 | **文系新卒 + 技术岗新卒（口头）**，统一综合职 prompt（已去掉模式开关） |
| 平台 | **v1 仅 macOS**（macOS 14+） |
| 质量优先级 | **日语答案质量 > 隐私 > 成本**（已选云端实时大脑） |
| CLI 定位 | **claude/codex 仅面试前预生成，不进实时路径** |
| 缓存原则 | **宁可不命中，绝不错命中** |

## 2. 待验证假设（Phase -1 通过前不锁定）

| 假设 | 风险 | 由哪个 spike 验证 |
|---|---|---|
| 用 Deepgram 做日语流式 STT | 日语质量/延迟未实测 | S2 |
| 用 Core Audio Process Tap 采集 App 音频 | 选源/权限/多进程/设备切换未验证 | S1 |
| 刘海作为主交互（自动展开 UX、屏共享可见性、多屏） | 连续监听场景下的 UX 与暴露风险未验证 | S4 |
| 3 秒 SLA 可达 | 计时口径未定、未压测分位 | S3 |
| 现有"监听→final→生成"足够 | 真实对话有插话/补问/backchannel | S5 |
| 本地 vs 云端边界 | 取决于 S2/S3 实测 | S2/S3 |

---

## 3. Phase -1：技术真实性验证（先做这个）

> 目标：用最小代码撞最硬的墙。**全部门槛通过前，不写实时大脑、不锁 §2、不堆功能。**

### S1 — 音频采集真实性（最大风险）
- **验证矩阵**：
  - 平台 × App：Zoom(app) / Meet(Chrome、Safari) / Teams(app) / 就活ツール(浏览器) → 能否稳定定位**面试官那一路**音频。
  - Chrome 多进程：helper 进程、多标签、应用重启后的 **PID 变化**与重新绑定。
  - 设备热切换：AirPods ↔ 有线 ↔ 内置，采样率变化(44.1/48k)，切换后自动恢复不崩。
  - 睡眠/唤醒、会议中途加入。
  - 干扰：系统通知声、多人同时说话、面试官与候选人 **overlap**。
  - 失败恢复：tap 失效后自动重建。
- **Process Tap 与 ScreenCaptureKit 不是可互换方案**——分别实测选源/权限/稳定性，再决定主用谁。
- **通过门槛**：三大平台各能稳定拿到面试官单路音频；设备热切换/睡眠唤醒能自动恢复；连续 30 分钟无丢流。

### S2 — 日语流式 STT 质量 + 延迟
- 真实/拟真日语面接音频（敬語、外来語、专业术语、电话/压缩音质）。
- 指标：**意图相关词**的错误率（不是整体 WER）、interim 首字延迟、final **稳定**延迟。
- 横评：Deepgram vs Google STT v2（vs 本地 kotoba 作参考）。
- **通过门槛**：意图相关词错误率 ≤ 阈值（暂定 ≤10–15%，按实测定）；final p95 ≤ 0.8s。

### S3 — 真实计时口径 + 压测（见 §4）
- 实装一条最简管线（S1 音频 → S2 STT → 任一快模型 → 刘海出现首句完整回答），按 §4 协议测 **p50/p95/p99**，含冷启动/重连/排队。
- **通过门槛**：现场生成 p95 ≤ 3.0s 且 p50 ≤ 2.0s（冷启动首轮单列报告，不混入）。

### S4 — 刘海可见性 + 多屏
- 屏幕共享时刘海 panel 是否进入被共享画面（Web 面接通常不共享，但**必须知道**）。
- 多屏：主屏 / 外接屏 / 无刘海屏的几何与放置；全屏会议 App 下是否仍可见。
- **通过门槛**：每种情形行为明确；默认配置下不会在面试官可见画面里暴露。

### S5 — 对话现实性
- 采集/标注真实或模拟面接样本：补充式提问、插话、连续两问、backchannel（「そうですね」「なるほど」）。
- 纸面 + 离线跑 §6 状态机草案。
- **通过门槛**：backchannel 不误触发；新问题能取消上一轮；补充提问能合并。

> Phase -1 产出 = 一份实测报告 + go/no-go：决定是否锁定 Deepgram / Process Tap / 刘海 / 3s SLA，或换方案。

---

## 4. 「3 秒」测量协议（先把指标定义清楚）

之前的表格自相矛盾（既说"问完了"才计时，又把判停算进预算；且测的是"首字"而非"首句完整回答"）。统一为：

- **起点 T0**：录制音频波形里**面试官最后一个音素结束**（离线 ground-truth 标注）。
  - 注意：`T_endpoint −T0` = **判停延迟**，是预算的一项，**不是**计时起点。
- **终点 T1**：**第一句完整、稳定、可直接开口朗读的回答**在刘海渲染完成。
  - TTFT/首字只是内部子指标，**不作为 SLA 终点**。
- **指标**：SLA = `T1 − T0`，报告 **p50 / p95 / p99**，over N 个真实样本、多场景。
- **必须包含**：进程冷启动、首次 WS 连接、WS 重连、LLM 排队/限流、网络抖动。
- **分类报告**：命中缓存 / 现场生成 两条曲线分开。
- **门槛**：现场生成 p95 ≤ 3.0s、p50 ≤ 2.0s；命中缓存 p95 ≤ 1.2s；冷启动首轮单列。

---

## 5. 模块结构（按职责）

标 `⏱` = 3 秒关键路径。

- **`Audio`** — `AudioCapture`⏱（App 音频采集，平台相关，唯一需为 Windows 重写）、`Endpointer`⏱（VAD + 语义判停）。
- **`STT`** — `SttClient`⏱（流式日语，provider 抽象，interim+final，重连）。
- **`Brain`** — `TurnManager`⏱（状态机 + epoch + commit，见 §6/§7）、`Router`⏱（**意图分类与缓存判定合并为一次调用**，见 §7）、`LiveAnswerGenerator`⏱、`ConversationContext`。
- **`Knowledge`** — `FactStore`（**结构化事实模型**，见 §8）、`AnswerBank`（预生成、用户审定、版本化）。
- **`Prep`** — `CliRunner`（**重构** SPI-killer 的 CLIRunner，见 §9）、`PreGenerator`（一貫性校验 + 精修 → AnswerBank）。
- **`UI`** — 刘海：`NotchShape`/`Indicator`（直接复用）、`NotchPanel`/`NotchController`/`NotchView`（参考重构，多屏/动态尺寸/由 TurnManager 驱动）、`AnswerModel`；以及 `ControlPanel`、`Hotkeys`、`PrepUI`（普通窗口）。
- **`Core`** — `ProviderRegistry`、`Secrets`（**Keychain**，见 §10）、`Config`、`LatencyMonitor`、`Prompts`（就活，重写）。

---

## 6. 对话状态机 + 取消规则（epoch）

```
idle/listening → possibleEnd → generating → presenting
         ▲            │             │            │
         └── backchannel/补问回流 ◀─┘            ▼
                                          candidateSpeaking
   任意新 final 问题 → bump epoch → interrupted/superseded → 新一轮
```

- **epoch（turnID）单调递增**：每个 STT/检索/LLM/UI 写入都带 epoch；**只有当前 epoch 的写入被接受，旧 epoch 一律丢弃**——这就是统一的取消语义。
- **backchannel**：短词/语气词（时长 + 内容启发式或小分类器）→ **不进 generating**。
- **possibleEnd 期间面试官继续**：回 listening，合并文本。
- **generating/presenting 时来新 final**：bump epoch，取消旧 STT/检索/LLM 流与 UI 写入，进新轮。
- **presenting 时候选人开口**（mic VAD）：转 candidateSpeaking，停止追加，保留已 commit 回答。

---

## 7. 投机生成的 winner / commit 规则

- **路由合并**：`Router` 一次调用输入"问题 + 向量召回 top-K 候选"，输出"**意图 + 命中索引/none**"，消除"意图分类 vs CacheRouter 谁先"的歧义，省一次往返。
- **候选暂存**：cache-candidate 与 live-candidate **先不画 UI**。
- **commit 单位** = **第一句完整且稳定、可直接朗读的回答**；谁先产出合格首句谁 commit。
- **commit 后锁源**：本轮不换源、不反转、不闪烁。后到的另一源结果丢弃；实时来源只继续追加后续句子，**不改已 commit 内容**。
- **缓存延迟命中**（live 已 commit）→ **不替换**。
- **被取消（旧 epoch）的流永不写 UI**（由 §6 的 epoch 保证）。

---

## 8. 知识层：结构化事实模型（不是泛化 RAG）

泛化向量 RAG 漏检关键事实时，LLM 会编出"听起来对、实则与 ES 冲突"的答案。所以核心是结构化事实库：

- **Experience**：`{id, role, org, period, actions[], quantified_results[], skills[]}`
- **Motivation**：`{id, target_company?, statement, evidence_refs[], キャリア軸}`
- 每条：`source`(ES/面接控/手填)、`version`、`locked`(bool)、来源引用。
- **生成约束**：检索 = 结构化查询 + 向量兜底；prompt 注入"允许使用的 fact 集合 + 禁止发明"；**回答中的事实主张可追溯到某 fact id**。
- **一貫性校验**（预生成时）：答案 vs ES facts 交叉检查；冲突/缺失 → **标记让用户补，绝不让模型编**。
- **字段级禁造**：无 fact 支撑的具体数字/经历不得出现。

---

## 9. SPI-killer 复用（三档，纠正此前高估）

| 档位 | 文件 | 说明 |
|---|---|---|
| **直接复用** | `NotchShape`、`RoseLoader` | 纯绘制/动画，无耦合 |
| **参考重构** | `NotchPanel`、`NotchController`、`NotchView` | 去掉写死 `NSScreen.main`/600px，支持多屏/动态尺寸；pipeline 改由 `TurnManager` 驱动 |
| **只借思路/部分** | `CLIRunner`、`Settings`、`AppDelegate`/`main` | CLIRunner 需：**通用文本任务接口**（去掉 imagePath/depth 硬绑）、**真正的 cancellation handle**、**并发安全的独立临时目录**、**codex 非结构化 stdout 的处理**；Settings 换 **Keychain + 加密**；accessory 启动思路可用但要 `.app` bundle |
| **丢弃** | `ScreenCapture` | 无屏幕识别 |
| **重写** | `Prompts` | 就活 system prompt |

---

## 10. 安全与隐私（因为选了云端，必须正面处理）

- **API Key → Keychain**（不是 UserDefaults）。
- **本地数据加密 at rest**：转写、ES、答案库；提供**一键删除**。
- **日志脱敏**：不落简历、问题全文、密钥；**崩溃报告同样过滤**（不得含简历/问题/密钥）。
- **录音状态可见 + 一键暂停监听**（醒目指示器）。
- **云端供应商数据保留**：明确并配置 Deepgram/LLM 的 zero-retention / no-train 选项，写进设置页与文档。

---

## 11. macOS 交付（不能留到打磨阶段）

- **`.app` bundle + Info.plist**：`NSMicrophoneUsageDescription`、屏幕录制/音频采集用途描述。
- **稳定 Bundle ID**：TCC 权限稳定的前提——**ID 变动会导致权限反复重新授权**，必须 Phase 0 就定。
- **签名 + 公证 + Hardened Runtime**（Developer ID）。
- **原生依赖打包**：sqlite-vec / ONNX / CoreML 模型随 app 分发。
- **自动更新（Sparkle）、崩溃恢复、开机启动（SMAppService）**。

---

## 12. 路线图

- **Phase -1（gate）** — §3 全部 spike + 报告 + go/no-go。**未通过不进 Phase 0。**
- **Phase 0 — 命脉** — 在通过的方案上打通"音频→STT→快模型→刘海"，含：§4 正确计时、§6 状态机最小版、§7 commit 规则、§10 Keychain、§11 稳定 Bundle ID + 签名骨架。验收 = §4 门槛达标。
- **Phase 1 — 质量** — §8 结构化事实模型 + 一貫性；就活 prompt（统一文系総合職）。
- **Phase 2 — 预生成 + 缓存路由** — `CliRunner` 重构 + `PreGenerator` → `AnswerBank`；`Router` + 投机 + commit；`PrepUI`。
- **Phase 3 — 打磨** — 语义判停、深掘り、furigana、刘海状态细节、加密/删除、自动更新、LatencyMonitor 仪表盘。

---

## 13. 风险登记册

| 风险 | 严重度 | 对策 | 验证 |
|---|---|---|---|
| 音频采集不稳/选错源 | P0 | S1 矩阵 + 自动恢复 | Phase -1 |
| 3s 口径混乱/达不到 | P0 | §4 协议 + 分位压测 | Phase -1 |
| 对话状态处理不了插话/补问 | P0 | §6 状态机 + epoch | Phase -1/0 |
| 投机生成答案闪烁/反转 | P0 | §7 commit 锁源 | Phase 0 |
| 缓存误命中 | P0 | 路由裁判 + 保守偏置 + 现场兜底 + 意图标签 | Phase 2 |
| 复用高估导致返工 | P1 | §9 三档复用 | — |
| 密钥/简历泄露 | P1 | §10 Keychain + 加密 + 脱敏 | Phase 0 |
| 交付/权限反复 | P1 | §11 稳定 BundleID + 签名公证 | Phase 0 |
| ES 一貫性被模型编造破坏 | P1 | §8 结构化事实 + 禁造 | Phase 1 |
| 无刘海 Mac / 外接屏 | P2 | 几何回退顶部小条 | Phase 0 |

---

## 14. 外部参考实现复用映射（Natively / Vijaysingh）

> **前提**：Natively = Electron+Rust+TS，Vijaysingh = Next.js/TS——**都不是 Swift，没有一行代码能直接复用**。能拿的是**架构模式、具体配置值、踩坑教训**，代码全部 Swift 重写。这跟 §9（SPI-killer 同为 Swift、有真实代码复用）性质不同，别混。
> 源码在 `/tmp/fi-ref/natively` 与 `/tmp/fi-ref/vijay`（临时 clone，可删）。

### 14.1 直接验证了我们的决策
- **音频**：Natively 正是 **CoreAudio process tap（14.4+）+ ScreenCaptureKit 回退（14.2–14.3）**，与 §3 S1 一致 → 方向对，Swift 原生调这些 API 比它的 Rust FFI(`cidre`) 更简单。`native-module/src/speaker/core_audio.rs`、`sck.rs`
- **延迟**：Vijay 现场 RAG 路径实测 3–6s、明说可能破 3s → 验证 §8「面试前预生成 + 缓存」而非现场 RAG。
- **密钥**：Natively 用 Electron safeStorage(=Keychain) → 验证 §10；Vijay 把 Deepgram key **硬编码进客户端** `components/recorder.tsx` → **反面教材**，强化「永不客户端存密钥」。
- **取消**：Vijay **完全没有** turn 取消，连问会同时流两个答案 → 验证 §6 epoch 的必要性。
- **采集方式**：Vijay 靠浏览器 `getDisplayMedia` 需要候选人**共享屏幕**（尴尬+可见）；我们原生 tap 不需要 → 验证原生路线更优。

### 14.2 值得直接抄的「模式 / 配置值」（在 Swift 重写）
| 来源 | 可移植的东西 | 用在 |
|---|---|---|
| Natively `liveDeadlines.ts` + `raceStreamWithDeadline` | **首字超时 → 首字后切「token 停顿守卫」**的双段 deadline；race token-stream vs deadline；输家 promise 静默 | §4 / §7（把它的 1200/1800/2500ms 收紧到 3s 目标） |
| Natively `IntelligenceEngine`（投机） | 高置信 partial（≥7 词 / ≥0.75 / 350ms 去抖）预启 LLM；定稿后 Jaccard/containment >0.75 则复用 | §7 投机阈值起点 |
| Natively `AnswerPlanner` | 答案类型模板（STAR、**禁止编造指标**） | §8 禁造、§5 Prompts |
| Natively STT 抽象 | 统一 `transcript{text,isFinal,confidence}` 接口 + **重连期 ring-buffer 不丢音** + final 去重 coalescer | §5 SttClient/ProviderRegistry |
| Natively 音频踩坑 | monitor **懒初始化**(避免启动 1s 静音)、stop 后丢残包(竞态)、48k→16k 重采样、设备 UID 映射、teardown 阻塞 100–300ms | S1 AudioCapture |
| Vijay Deepgram 参数 | `nova-2, interim_results, smart_format, punctuate, diarize:false, utterance_end_ms:1000, vad_events:true, endpointing:300`（换 `language=ja` / nova-3） | S2 起始配置 |
| Vijay 转写去重 | 归一化文本集合 + 两次 final 最小间隔（注意它的 1s 间隔会拖慢连续追问） | §6 SttClient |
| Natively safeStorage / sqlite-vec / 打包 | Keychain 加密、sqlite-vec 本地向量、签名公证 + 模型放 `extraResources` | §10 / §8 / §11 |

### 14.3 刻意不照搬
- **泛化向量 RAG**（两者都用）→ 我们用 §8 结构化事实模型；只借 sqlite-vec 存储，不借「切块 + 纯相似度检索」。
- **Vijay 两段串行路由**（先非流式 knowledge-check ~500ms 再生成）→ 我们 §7 合并成一次调用，3s 预算扛不住串行两跳。
- **Natively 宽松超时**（首字 7s）→ 我们 3s，更激进 + 更靠预生成命中。
- **Cluely 式隐蔽 / 键盘 tap / 进程伪装** → Web 面接不共享屏幕，不需要，省复杂度与风险。
- **现场 web 搜索（Tavily）** → 就活要的是与 ES 一貫，不是网搜，砍掉。

### 14.4 它们暴露、我们要提前防的坑
- 模型冷启动（intent/ONNX/本地）拖垮首答 → Phase 0 **启动即预热**所有模型/连接。
- 投机浪费（命中率低就白算）→ 仅高 turnover 时投机 + 记录命中率。
- 无限流恢复 → 限流时降级到备用 provider / 本地，别硬失败。
- 简历泄露无 token 级拦截 → §8 输出后置过滤（禁第一人称泄露事实）。

---

## 15. 实现进度（STATUS）

代码 `swift build` 通过；`scripts/bundle.sh` 产出带稳定 BundleID 的 `.app`（`scripts/dev-run.sh` = 重打包+杀旧+重启的开发循环，`.app` 跑的是 release 二进制，改完代码必须重打包才生效）。mock 管线运行时验证通过；**`.live` 已用合成日语（`say -v Kyoko`）端到端冒烟跑通**：tap 采到系统输出音频、Deepgram 日语转写准确（4 句 3 句逐字、keyterm 全中）、`[latency]` 在 3s 预算内。

### ✅ 已实现（code-complete，可编译可运行）
- **Phase 0 命脉**：accessory 引导 + 刘海 UI（Panel/Shape/View/Controller/Indicator/AnswerModel）+ 管线（AudioCapture→STT→TurnManager→AnswerGenerator→notch）+ Keychain Secrets + `.app` 打包（稳定 BundleID + Apple Development/ad-hoc 签名）。
- **Phase 1**：结构化事实模型（FactStore/Fact）+ 接地到生成 + 就活 prompt（Prompts，文系総合職）。
- **Phase 2**：意图清单（Intents）+ AnswerBank + Router（LLMRouter：intent+match 合并一次调用、保守偏置）+ 并行 commit（§7）+ CliRunner（通用化、隔离 temp、真 cancel）+ PreGenerator（离线建库）。
- **Phase 3（部分）**：状态栏控制面板 + 全局热键（⌘⇧Space/P）+ 暂停/恢复 + 一键删数据（§10）+ 深掘り 历史。
- **面接原稿导入**（兑现 §1「用户审定」/ §5 PrepUI 的一半）：`ScriptParser`（约定格式 Markdown 离线确定性解析，无需 key）+ `ScriptStore`（存 `knowledge/script.json`，`locked`，不被预生成覆盖、随删数据清除）+ `PrepWindow`（导入/粘贴/实时预览/保存）；并入 Router 候选（命中→逐字提示，脚本置前优先）+ live 上下文 grounding（未命中→喂给 LLM）。
- **§4 忠实计时**：`LatencyMonitor` 以「最后有声帧」近似 T0（判停延迟入预算）、缓存/现场分列、p50/p95/p99、冷启动单列。
- **启动即预热**（§14.4）：启动即热 LLM HTTPS/H2 连接，消首问连接冷启动（净收益受 LLM 服务端延迟浮动限制）。
- **面试前自检**：🎤 菜单显示「面接官の音声 / STT 接続 / Deepgram / 回答 LLM」四项就绪（按 tap 是否启动判定，菜单打开即刷新）。
- **Provider**：Deepgram STT（nova-3 + 就活 keyterm，参数对齐 §14.2）/ Gemini / Claude / FastLLM（非流式，供 Router/Prep/预热）。

### ⏳ 需在真机验证（缺真实通话/真人音质，合成 TTS 替代不了）
- **完整 Phase -1 gate**：S1 三平台音频稳定性 + 设备热切换/睡眠唤醒自动恢复 + 30 分钟无丢流；S2 真人/压缩音质日语准确度（已见同音词 `志望`→`死亡` 误识）；S3 真实多样本 p50/p95/p99 压测（含冷启动/重连/限流）；S4 刘海可见性·多屏；S5 对话现实（插话/补问/backchannel）。
- 合成冒烟仅证明「单链路通 + 干净音质下准确 + 延迟在预算内」，**不等于过 gate**。

### 🔧 剩余 polish（已登记，未做）
- **音频**：设备热切换/睡眠唤醒**自动重建 tap**（采样率变化时重建 converter）、per-process 选源（替代全局 tap）、`CoreAudioTapCapture` ring-buffer。
- **大脑**：语义判停（替代纯 `speech_final`）、mic-VAD 的 `candidateSpeaking`、furigana ruby、§4 投机（高置信 partial 预启 LLM）。
- **安全/交付**：facts/bank/script 静态加密、日志脱敏（现仍落问题全文，§10）、云端 zero-retention 配置、Developer ID 公証 + Sparkle 自动更新 + SMAppService 开机启动（§11）。
- **UI/工程**：facts/ES 上传·审阅 GUI（PrepUI 的另一半）、LatencyMonitor 可视化、Swift6 严格并发（消除 `@Sendable` 警告）。
