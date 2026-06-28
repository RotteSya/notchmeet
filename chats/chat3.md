# 刘海遮挡页眉问题

_Started 2026-06-26 07:43 UTC_

---

## User

现在刘海会把页眉的元素挡住，你觉得应该怎么办？

## Assistant

_[tool: read_file]_

_[tool: show_html]_

This is a design judgment question, so let me see the actual overlap first.

_[tool: save_screenshot]_

_[tool: save_screenshot]_

_[tool: show_html]_

_[tool: save_screenshot]_

I can see the problem clearly now. At rest the collapsed notch (248px) has clearance, but when it **expands to 548px** it grows sideways over both the nav links on the left and the language switcher / clock / download button on the right.

My recommendation: solve it the way the real macOS notch does — **the notch owns the center, and the menu bar yields to it.** Two parts:

1. The resting (collapsed) notch already clears the side groups — keep that.
2. When the notch *expands* (the transient demo moment), let the menu bar gently recede behind it so the overlap reads as a deliberate panel sliding down over a quieted bar, not a collision. This matches the system's "whole product moves as one body" motion philosophy and is exactly how a Dynamic-Island-style expansion takes focus.

Let me implement that.

_[tool: str_replace_edit]_

Now wire the bar to recede when the notch opens:

_[tool: str_replace_edit]_

_[tool: ready_for_verification]_

My take: treat it like the real macOS notch — the notch owns the center, and the menu bar yields to it.

What I changed: the collapsed notch already had clearance from the side groups, so the fix targets the expanded state. Now when the notch expands, the menu bar gently recedes (opacity → 0.32, non-interactive) behind it, so the overlap reads as a deliberate panel sliding down over a quieted bar rather than a collision — and it snaps back as the notch collapses, matching the system's single-morph motion.

If you'd prefer a different direction — e.g. permanently capping the side groups so nothing ever sits behind even the expanded notch (more macOS-literal but tighter on narrow screens), or moving the notch demo down into the hero instead of fusing it to the bar — say the word.

## User

还是挡住了页眉元素

## Assistant

You're right — at this window width the panel is simply too wide and dimming isn't enough; the elements are still physically covered. The real fix is to never let the notch grow over the side groups. I'll make the expanded width **responsive** so it always leaves room for the menu-bar groups, and keep those groups fully visible (no dimming).

_[tool: str_replace_edit]_

_[tool: str_replace_edit]_

_[tool: str_replace_edit]_

_[tool: str_replace_edit]_

Let me verify there's no overlap at this narrow width.

_[tool: save_screenshot]_

Let me confirm the actual geometry with real measurements rather than the scaled screenshot.

_[tool: eval_js]_

The earlier numbers were mid-transition (width was still animating from 548). Let me give a bit more margin and measure cleanly.

_[tool: str_replace_edit]_

_[tool: eval_js]_

Clean now — 81px left, 19px right clearance, no overlap at this narrow width (and more room at wider sizes). The notch grows downward and only as wide as the center allows.

_[tool: ready_for_verification]_

Fixed. The expanded notch now sizes to the available center band instead of a fixed 548px — it reserves a gutter on each side for the menu-bar groups, so the nav links (left) and language switcher · clock · download (right) stay fully visible and uncovered at any window width. It also recomputes on resize.

