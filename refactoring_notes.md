# 备战驾驶舱重构笔记

> 阶段三实施期间的兼容性/性能瓶颈随做随记。方案见提案（artifact「备战驾驶舱重构提案」）。
> 决策已对齐：①新工作台窗口 ②Genie 吸入动效 ③引用优先+置信分层抽取 ④答案库按目标分文件 ⑤JD v1 只留字段。

## 步骤 1 · 引擎层（Target 模型 + Store + provenance + Portrait）

- **新增**（引擎私有仓）：`Target.swift`（InterviewTarget/TargetEmphasis/TargetLibrary）、
  `TargetStore.swift`（照抄 ScriptStore 纪律：0600/原子写/corrupt 隔离+只读降级/保存失败告警）。
- **改动**：`Fact.swift` 加 `Provenance{source,quote}`，Experience/Motivation 挂 `provenance:`
  （Optional 红线：显式 init 保持既有调用点兼容）；`Portrait.swift` rebuild 加
  `target: InterviewTarget? = nil`。
- **坑 1**：`Experience`/`Motivation` 原靠合成 memberwise init，加字段会改变签名破坏全部调用点
  —— 补显式 init、新字段带默认值，既有调用点零改动。
- **坑 2**：TargetStore 播种幂等性的判据必须是「文件是否存在」而不是「列表是否为空」：
  用户删光目标后 targets.json 仍在（空列表），据此绝不重播，否则删掉的目标复活。
  产出为零时不落盘（保持 .empty），下次启动无害重试。
- **坑 3**：save() 成功后要把 `.empty` 翻成 `.ok`——首次 add 后状态仍是 .empty 的话，
  后续 seedIfNeeded 会把用户手建的库整个覆盖。
- **设计**：emphasis 置顶与指代钉住（deictic pinnedIDs）在 pack 层合流——语义相同
  （必须在视野内）；排除项在**编译期**过滤（检索无从召回，比 pack 期跳过更硬）。
  identity 有 target 时只报本场公司+岗位，别家志望不进 identity。
- **验证**：`swift test` 全量绿；新增 TargetStoreTests（持久化/corrupt/播种幂等/缺键解码）
  + PortraitTargetTests（identity 隔离/排除不可见/置顶保底）。

## 步骤 2 · 解析层（ResumeReader + PDF/OCR + 受限抽取）

- **新增**（公开仓 Prep/）：`ResumeReader.swift`（协议 + ResumeDocument/TextBlock +
  TextResumeReader + ResumeReaders 分发器）、`PDFResumeReader.swift`（PDFKit 逐页；
  文本层 <40 字判扫描件 → Vision 离线 OCR zh/ja/en，2x 渲染，12 页封顶）、
  `ResumeExtractor.swift`（离线分节 + 受限 LLM 抽取）。Localization 加 2 条 PDF 错误文案。
- **约束落地**：每条事实必须带 src 定位片段；空白归一化后能在原文对齐 → provenance 带
  引用；对不齐 → quote=nil 低置信（UI 显示「AI 不确定」）；notes 无 provenance 可挂，
  对不齐直接丢弃；整体空产出 → 退回离线分节。抽出的一律 locked=nil（草稿态）。
- **计费/隐私**：chargeOneShot 60s/份（额度不足退回离线，不失败）；isLLMAvailable 走
  sendContextToLLM 同一道门（第 5 个消费点）。
- **坑 1**：PDFKit `isLocked` 与 `isEncrypted` 语义不同——空密码加密件已自动解锁、可读，
  只有 isLocked 才该报「需要密码」。
- **坑 2**：分节标题启发式必须全靠词表兜底（短行+无句读会把「负责后端开发」误判成标题），
  英文词全等匹配、CJK 词允许包含匹配。
- **验证**：ResumeExtractorTests 12 项（读取块切分/页码、分节词表、对齐→引用、
  不对齐→低置信、note 丢弃、垃圾拒收、传输失败回退）。OCR 路径留真机验收（无 fixture）。

## 步骤 3 · 备战工作台（三栏驾驶舱）

- **新增**（UI/Workbench/）：WorkbenchStrings（中日文案表，沿用 OBStrings 分表先例）、
  WorkbenchWindow（窗口纪律照抄 SettingsWindow：保活/accessory/sharingType none/QA 豁口）、
  WorkbenchRoot（三栏骨架 + Combine 联动）、WorkbenchTargetRail（目标列表 + 武装点 +
  弹簧 pill + 右键删除）、WorkbenchAmmoPanel（弹药卡片 + 统一装填入口 + 出处引用 +
  确认/必带/不带/删除）、WorkbenchReadiness（自检镜像 + 弹药进度条 + 准备面试）。
- **入口**：菜单「打开备战工作台…」+ `FI_OPEN_WORKBENCH=1`/`--open-workbench` QA 钩子；
  armed 骨架 `prepareForInterview(target)` 已接（切目标→兑现绑稿→画像/热词→预热→收窗
  →刘海脉冲），飞入动画留给步骤 6。
- **偏离提案的决定**：设置窗的 原稿/事实/复盘 三个分区**暂不迁走**——工作台的卡片确认
  是轻编辑面，全文编辑仍复用设置窗的成熟编辑器（卡片上有「在设置中编辑全文」直达）。
  两面共享同一批 live store，不存在数据分裂；等工作台被真实使用验证后再做减法。
  离线解析的「分节预览」也未做成独立 UI（状态行 + 手动整理路径承担），后续按需补。
- **坑 1**：首屏三栏各说各话——rail.reload() 把初始选中解析到武装目标但不广播；
  viewDidMoveToWindow 必须整体 refresh() 而不是只 reload 目标栏。
- **坑 2**：中栏可用列宽仅 ~408pt（窗口 1000 − 220 侧栏 − 300 战备栏 − 36×2 内边距），
  三个头部字段 220/160/140 直接把第三个挤出画面；收窄到 168/118/100。
- **坑 3**：QA 下 readiness 调 currentHealth() 会走 Settings.apiKey——幸而 Keychain 在
  Secrets 层集中门禁（demo 管线返回 nil 不弹框），无需在 UI 层重复防。
- **简历 vs 稿件分流**：`ResumeExtractor.resumeOnlyHeadings` 是**刻意与稿件话题零交集**的
  子集（志望動機/自己PR/自我介绍绝不能进表，否则日文稿被误判成简历）；≥2 信号→简历，
  否则问答覆盖率≥0.55→稿件。杂乱稿件会落到简历路径——设置窗的稿件导入仍是兜底入口。
- **验证**：`swift test` 全量绿；FI_UI_DEMO+FI_OPEN_WORKBENCH 实机截图三轮
  （scratchpad/wb-qa-3.png 为验收版）。

## 步骤 4 · 引导改造（7→8 步）

- **插入「你的目标」步**（index 2）：面试语言分段（即时写 Settings.interviewLanguage，
  setter 自广播）+ 公司/岗位字段，三项全可跳过；每个控件下方一行小字写明它改变什么
  行为（透明即尊重）。落库走控制器侧 **按公司名 upsert**——引导可重开、完成页可重复
  到达，不许长出重复目标。
- **「导入原稿」→「装填弹药」**：文件面板改收 ResumeReaders.openPanelTypes（+PDF）。
  分流规则：PDF 一律按简历；文本命中 ≥2 简历专属标题按简历。简历**不进原稿编辑器**，
  只登记 + 说明去向，引导结束后移交工作台 `importResume(url)` 走完整解析确认流
  （复用面板的隐私/额度门与三段式反馈——引导里不假装完成解析）。
- **完成页**：语言行从 OBStrings 硬编码改读 `AppStrings.languageSummaryValue`（此前
  中文面试用户在完成页会看到「面试与回答：日语」的假话）；新增目标/简历总结行（跳过
  则不显示）；落点从「关窗完事」改为 `openWorkbench()`。
- **步骤编号**：kicker 文案 STEP 1-5 重排（目标=1 原稿=2 权限=3 激活=4 演示=5）；
  goToFirstUnmet 索引 4/5；FI_OB_STEP 范围 0…7；OnboardingWindow 增加 QA 窗口号文件
  `/tmp/nm-onboarding-window.txt`（与设置窗同款按 ID 截图法）。
- **验证**：全量测试绿；FI_OB_STEP=2/7 截图验收（scratchpad/ob-target-step.png、
  ob-done-step.png）——目标步 3/8、完成页语言行动态。

## 步骤 5 · 管线接线（目标维度贯通）

- **热词**：武装目标的 公司+岗位+emphasis.keywords 排最前，其后才是稿件公司/志望公司/
  经历。**JD 刻意不自动抽词**（决策⑤只留字段）：长文分词的杂草违背「热词表要小而准」，
  目标级热词只收用户手挑的 emphasis.keywords。
- **applyTarget(id) 单一路径**：设活跃 → 兑现绑定用稿 → 切目标答案库 → 画像重建 →
  热词下发。菜单选目标与「准备面试」共用（真相源一处）；启动与开录时各对齐一次
  bank.activate（防「换目标→直接开录」拿旧库）。
- **答案库分文件**：`banks/<targetID>.json`；无目标 = 旧全局 `answer_bank.json`；
  目标库缺失时**只读回落**全局库（存量用户武装目标不至于库瞬间清零），保存永远写
  目标自己的文件。AnswerBankTargetTests 盖住隔离/回落/重启三条。
- **菜单**：新增「本次面试目标」子菜单（有目标才显示，排用稿选择器上面；子菜单
  ScreenShareGuard.protect 同门）；自检加目标行。SessionRecord + targetID/targetCompany
  （Optional 红线），复盘数据就位（复盘 UI 按公司过滤留待后续）。
- **验证**：全量测试绿（新增 AnswerBankTargetTests）。

## 步骤 6 · 飞入仪式（Genie 吸入）

- **armed ≠ recording 落地**：`prepareForInterview` = applyTarget → prewarmLLM → Genie
  吸入 → 刘海吸气脉冲。不开录音不计费；降级链（Reduce Motion / 无 Metal / 薄片绘制
  失败）= 直接收窗 + pulse，仪式绝不挡 armed 本体。
- **Genie 实现**：40×48 顶点网格 + 运行时编译 vertex shader；每行独立进度（顶行先动，
  lag=0.55 错峰）+ out-cubic；x 随「当前高度接近开孔的程度」按 smoothstep^1.6 漏斗收拢；
  尾段 14% 全局淡出。飞行 NSPanel（statusBar 层、ScreenShareGuard 排除）压在**刘海
  Panel 之下**——内容滑进石板区域即被吞没，吸收错觉的全部。实测 ~112fps（ProMotion）。
- **⚠️ 快照血泪史（本步最大坑，五连败后转向）**：对这套 IOSurface 背衬的 layer-backed
  树，`cacheDisplay`/`layer.render(in:)`/`displayIgnoringOpacity` 全部返回全透明
  （逐像素 alpha=0 实测；CA 接管后 display 族方法不落 CG）；`dataWithPDF` 打印路径能画
  文本但滚动内容错位、plusLighter 混合失真；`CARenderer` 拒绝渲染已挂窗口的层树（输出
  品红）；`CGWindowList`/SCK 被 sharingType=.none 挡死——临时翻开会把弹药面板泄进共享
  帧，红线不做。**定论：macOS 现代合成架构下拿不到活窗口像素，属硬约束**。
- **转向：同设计系统直绘薄片**（`GenieFlight.SheetModel` + `drawSheet`）：用同一套 SK
  tokens + 同一批 live store 数据把工作台画像直绘成纹理（三栏/选中胶囊/武装点/弹药卡
  实虚线/战备行/进度条/主按钮全部入画）。0.6s 形变中无人阅读像素级文本，视觉血统一致。
- **坑 A**：CAMetalLayer 要作为 backing layer 的 **sublayer** 挂（`layer = metalLayer`
  替换 backing layer 在 AppKit 下不可靠）；QA 连拍要 `framebufferOnly = false`（帧缓冲
  专用纹理无法被窗口截屏回读）——但窗口级截屏对直通呈现依然拍不到，**验收走 GPU 内
  blit 回读**（`FI_FLIGHT_DUMP=/path` DEBUG 钩子，25%/50%/80% 各落一张 PNG）。
- **刘海侧**：NotchLuma 新增 `inhale()`（直接抬 energyShown、target 不动，step() 指数
  回落给 ~1s 呼吸尾巴 + flow 脉冲）；72% 进度触发吸气，落位再 pulse 收尾。
- **QA 钩子**：`FI_QA_FLYIN=1` 自动触发准备面试；`FI_SLOW_FLYIN=1` 2.4s 慢速；
  `FI_FLIGHT_DUMP` 帧回读。验收帧：scratchpad/flightdump-{25,50,80}.png。
- **验证**：全量测试绿；慢速飞行三帧逐段检查（漏斗成形→中段吸入→开孔收口）。

## 步骤 7 · 真机测试（真实数据 + 真刘海）

跑法：debug 二进制装进 `.build/NotchMeet-QA.app`（bundle 身份 + DEBUG 钩子），
`FI_VISUAL_QA=1`（sharingType 降 .readOnly 才截得到图）+ `FI_KNOWLEDGE_DIR` 指向
`~/Library/Application Support/notchmeet`。release `.app` 下 sharingType=.none，
**任何截图手段都拍不到**，所以真机视觉验收只能走这条 QA 通道。

- **🐛 真机首屏抓到的 bug（最重要的一条）**：工作台里切目标只调了
  `targets.setActive`，没有兑现绑定用稿——左栏选中 A 公司、右栏「稿件绑定」还是 B
  公司的稿，面试当场读的是上一家。**菜单栏那条路径走 applyTarget（对），工作台这条
  漏了**。教训：武装是一条链（活跃目标 + 绑定稿 + 答案库 + 画像 + 热词），任何 UI
  入口都必须回调到 `AppController.applyTarget`，绝不在视图层就地改 store。
  修法：`WBTargetRail.onArmTarget` 回调贯穿 Root→Window→AppController。
- **启动自愈**：`start()` 里把 `bank.activate(...)` 升级为 `applyTarget(activeID)`。
  存量不一致（旧版本或任何只改一半的路径留下的）在开机那一刻自动对齐。
- **播种兜底**：真实数据 5 份稿的 `company` **全是 null**（那是后加的字段），不兜底
  的话升级后工作台首屏全空、「准备面试」永远置灰。改为从稿件名提取第一段下划线前缀
  （`コグニザントジャパン_interview_integrated_2026-07-26` → 公司名），纯数字/日期/
  通用词一律放弃——播错公司名会污染热词与画像 identity，比少播一个坏得多。
- **setActive 幂等**：值没变不落盘（启动自愈与准备面试会用同一 id 各调一次）。
- **真机验证通过**：① 4 家公司正确播种并各自绑稿 ② 切目标后三栏与磁盘完全一致
  ③ PDF 简历解析链在真实简历（佘令钊-通用版.pdf）上跑通——5 经历/9 备忘，2 条对齐
  原文带 quote、3 条对不齐只留 source（置信分层真实发生）④ Genie 吸入在真刘海上
  漏斗成形→收口→吞没干净无残留。
