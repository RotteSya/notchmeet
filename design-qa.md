# NotchMeet Settings Design QA

The settings panel was rewritten **SwiftUI → pure AppKit** (2026-06-22) to match the product's
obsidian design language (notch + onboarding). The earlier flat warm-charcoal "Settings.app
clone" — criticized as generic/AI-looking — is gone.

- Viewport: 840 × 588 pt, macOS dark appearance, Retina 2× capture
- Build for capture: signed **DEBUG** `.app` (window is `sharingType=.none`; DEBUG `--visual-qa`
  flips it to `.readOnly`). Recipe in memory `settings-appkit-redesign`.
- Captures: `/tmp/nm-{general,keys,answer,privacy,scripts}.png`, editor `/tmp/nm-editor2.png`.

## Design language

- **Living Metal aurora backdrop** (`SettingsBackdrop`): deep, slow, double domain-warped fBm in
  brand blues; light pools upper-left behind the rail and falls to near-black under the reading
  column so type stays crisp. Triangular-PDF dither kills banding.
- **Full-height obsidian sidebar** with the traffic lights floating over it; a **liquid selection
  pill** springs between items on the display clock (critically-damped `Spring` + `DisplayLoop`),
  with a leading periwinkle tick of light.
- **Hand-drawn controls** (no stock NSControls): convex periwinkle primary key (CALayer shadowPath
  glow), hairline-glass secondary, segmented control with a sprung glass thumb, custom toggle with a
  sprung knob + accent-fill track, glass popup → real `NSMenu`, obsidian fields with an accent focus
  bloom, themed `NSTextView` well for the script editor.
- **Motion as one body**: sections crossfade + slide via `DisplayTween`; Reduce Motion jumps.

## Verified

- All six sections render with correct hierarchy, spacing rhythm, and localized copy (中/日), no
  truncation; 720pt readable-width cap holds.
- Pixel-level zoom on the toggle and segmented thumb: smooth gradients (no banding), crisp edges,
  clean contact shadows.
- Keys: accent check-circle ↔ empty-circle states, secure monospaced wells, save/clear hierarchy,
  SF Symbol `.bounce` on save.
- Scripts: populated list with active badge + hover-revealed actions; editor with parse-preview and
  themed text well; long titles truncate to one line beside ⌘S Save.
- Release build clean (QA hooks are all `#if DEBUG`); 23/23 tests pass.

final result: passed
