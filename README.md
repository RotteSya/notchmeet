# notchmeet — 落地页

[notchmeet](https://rottesya.github.io/notchmeet/) 产品落地页的源码。单页、纯静态、零构建。

> **产品一句话：** 把求职面试的实时辅助塞进 MacBook 刘海 —— 它在后台听问题、出答案，你瞄一眼照着念。
>
> 落地页是中文 UI，obsidian + edge-of-light 暗色材质系统，hero 区有一块跟随光标视差的 WebGL aurora，菜单栏的刘海会自动循环演示「待机 → 聆听 → 思考 → 流式 → 呈现」。

## 线上地址

https://rottesya.github.io/notchmeet/

## 本地预览

无构建步骤，用任意静态服务器起一下即可：

```bash
python3 -m http.server 8000   # → http://localhost:8000
```

> 直接用 `file://` 打开 `index.html` 也能看，但 WebGL aurora 和 Lucide 图标（走 CDN）在 http 下更稳。

## 结构

```
index.html              # 整页（语义化标记 + 内联结构）
css/
  design-system.css     # 设计系统 tokens + 材质/工具类
  landing.css           # 页面样式、关键帧、刘海过渡、按钮
js/
  aurora.js             # hero 背后的 WebGL fBm aurora shader（WebGL 不可用时回退 CSS 渐变）
  app.js                # 刘海状态机、滚动唤醒/待机、入场动画、视差、等候名单、时钟
assets/
  notchmeet-icon-256.png
```

页面分区（锚点）：`#top` 主视觉 → `#why` 痛点 → `#scene` 怎么用 → `#privacy` 数据去向 → `#pricing` 免费试用 → `#cta` 收尾。

唯一外部依赖：[Lucide](https://lucide.dev) 图标，走 `unpkg` CDN。

## 部署

GitHub Pages，"Deploy from a branch"，源 = 本分支 `implement-notchmeet-landing` 的 `/(root)`。
**更新方式：** 改完直接 `git push`，Pages 自动重建，约 1–2 分钟生效。

> ⚠️ 本分支是独立的 orphan 分支，与 `main`（NotchMeet macOS App 本体）没有共同历史，请勿合并到 `main`。
