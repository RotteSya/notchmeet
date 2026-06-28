# 面试稿回答逻辑说明

_Started 2026-06-27 08:55 UTC_

---

## User

体验章节改成要让用户清楚：命中面试稿里的问题时直接出回答，是面试稿里没有准备的问题时会通过分析面试稿出回答。

## Assistant

_[tool: read_file]_

The user wants the experience section (`#scene`) to clearly explain notchmeet's two answer paths: a direct answer when the question matches the prepared interview script, and an analyzed/generated answer when it doesn't. I'll add a labeled two-path explainer after the device theater, styled with the design system's cards.

_[tool: dc_html_str_replace]_

_[tool: ready_for_verification]_

体验章节加了一段双路径说明，放在产品演示下方:

- **命中面试稿** — 问题正中你准备好的那一条，直接呈现你写好的回答，照着念。
- **面试稿之外** — 没准备到的追问，分析你的面试稿与简历，临场生成贴合的回答。

上方一句话总结，下方两张卡片分别讲清两种情况，沿用了设计系统的卡片与配色。

