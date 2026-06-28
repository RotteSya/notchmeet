# 删除日本语版本

_Started 2026-06-26 16:40 UTC_

---

## User

删除日本语版本

## Assistant

_[tool: read_file]_

I'll remove the Japanese UI-language version (the toggle and all Japanese chrome strings), keeping Chinese as the only interface language. The notch demo's Japanese interview content stays — that's the product's core function.

_[tool: run_script]_

_[tool: grep]_

The JS references are fully gone — only the now-harmless `data-i18n` HTML attributes remain (they no longer do anything). Let me verify it loads and renders cleanly.

_[tool: ready_for_verification]_

Done. Removed the Japanese UI version — the 日本語/中文 toggle is gone and the page is now Chinese-only. Also stripped the Japanese chrome strings, the language state, and the switching logic from the code.

The notch demo's Japanese interview Q&A and status text stay as-is — that's the product's actual output (it generates Japanese answers for Japanese interviews), not a UI language version.

## User

删除工作原理章节

## Assistant

I'll delete the 工作原理 (`#flow`) section and clean up the now-dead links pointing to it. Let me read the current exact content first.

_[tool: read_file]_

Now let me read the flow section boundaries and the footer.

_[tool: read_file]_

I have the exact boundaries. Deleting the `#flow` section and cleaning up its now-dead links (menu nav, footer nav, and the hero "了解原理" button that only scrolled to it).

_[tool: run_script]_

No dead `#flow` or `tCta2` references remain. Let me verify it renders cleanly.

_[tool: ready_for_verification]_

Deleted the 工作原理 section (the 3 steps, latency budget, and status strip). Also removed the now-dead links to it: the 原理 nav item in the header and footer, and the hero's "了解原理" button — so the hero now has a single primary download CTA.

