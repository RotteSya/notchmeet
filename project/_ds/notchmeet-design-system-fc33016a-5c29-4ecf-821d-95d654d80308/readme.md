# notchmeet — Design System

> An obsidian, edge-of-light design language for **notchmeet**: a macOS notch-resident,
> real-time AI interview prompter built for Japanese job-hunting (就活 / *shūkatsu*).

---

## 1. Product context

**notchmeet** lives in the physical notch of a MacBook. During an online interview (Zoom /
Google Meet / Teams) it captures the **interviewer's audio only** — no mic, camera, or screen —
streams it to speech-to-text (Deepgram, Japanese), grounds the recognized question against the
candidate's résumé facts + prepared scripts, and renders a **ready-to-read Japanese answer** in
the notch within ~3 seconds. The candidate glances up and reads.

It is a calm, private, high-stakes utility. The whole product is the system typeface and a slab
of machined obsidian that *grows out of* the hardware notch. The design language was authored to
deliberately **kill every "generic / AI-slop" tell**: flat fills, banded gradients, hard
rectangles, snapping motion, blurry colored glows.

### Surfaces (there is one product, several surfaces)
- **The Notch** — the primary interface. Collapsed it is indistinguishable from the hardware
  notch (pure black, fused at the seam). Expanded it is an obsidian card showing the recognized
  question, the live answer, a status jewel, and record/settings controls.
- **Onboarding** — a five-step welcome window over a living "aurora" backdrop, with a breathing
  app-icon hero, a progress rail, and the convex accent buttons.
- **Settings** — six sections (General · Scripts · API Keys · Answer Engine · Privacy · About)
  over the aurora, with an obsidian sidebar and entirely hand-drawn controls.
- **Menu-bar control panel** — a status menu (start/stop recording, pre-flight self-check,
  visibility toggle, delete-data).

### Sources
- **Codebase (read-only, mounted):** `notchmeet/` — a Swift / AppKit + SwiftUI Swift-Package
  macOS app. Design language lives in:
  - `Sources/notchmeet/UI/Notch/NotchDesign.swift`, `Indicator.swift`, `NotchShape.swift`
  - `Sources/notchmeet/UI/Onboarding/OBDesign.swift`, `AuroraBackground.swift`
  - `Sources/notchmeet/UI/Settings/SettingsKit.swift`, `SettingsControls.swift`
  - Copy + tone: `Sources/notchmeet/Core/Localization.swift`
  - Product spec: `PLAN.md`, `design-qa.md`
- **App icon:** `uploads/icon-256.png` (also `Resources/AppIcon.png`).

> ⚠️ **Font substitution flag.** The app uses the Apple **system face (SF Pro + SF Mono)** and
> Apple **SF Symbols** for iconography — neither is redistributable as a webfont/iconset. This
> system therefore renders the native system-font stack (`-apple-system` → SF Pro on Apple
> hardware) and substitutes **[Lucide](https://lucide.dev)** icons (rounded, ~1.5–2px stroke) as
> the closest CDN match for SF Symbols. On non-Apple devices the type falls back to Segoe/Roboto.
> If pixel-exact SF Pro / SF Symbols are required, supply the licensed assets.

---

## 2. Content fundamentals (voice & copy)

notchmeet is **bilingual by architecture**: the UI *chrome* follows the user's UI language
(Chinese `zh` or Japanese `ja`); the *product content* (the interview question + the generated
answer) is always **Japanese**. All copy below is drawn from `Localization.swift`.

- **Tone:** calm, precise, reassuring, privacy-forward. It never hypes. It tells you exactly
  what is happening and where your data goes. Status lines are short and factual:
  *待机中 · 点击圆点或 ⌘⇧P 开始录音* / *待機中 · ●をタップ／⌘⇧Pで録音開始* ("Standby · tap the
  dot or ⌘⇧P to start recording").
- **Person:** addresses the user as **you / 你 / あなた**; the app refers to itself by name
  (*notchmeet*), lower-case, never capitalized.
- **Casing:** UI labels are sentence-or-noun case, not Title Case. The one uppercase device is
  the **kicker** (a tiny tracked label like `STEP 02`).
- **Separators:** the middle dot **·** and full-width **・** join clauses; keyboard shortcuts are
  shown inline (`⌘⇧Space`, `⌘⇧P`, `⌘S`).
- **Emoji:** used *only* as functional status glyphs, never decoration — `🎙`/`🎤` self-check,
  `🔴` recording, `⦿` standby. Everything else is an SF-Symbol icon.
- **Privacy language is first-class.** Consent and data-flow copy is plain and complete:
  it names the call app, the STT vendor, the LLM, and states "API キーのみ端末内に保存されます"
  (only the API key is stored on-device). Reassurance over persuasion.
- **Numbers are concrete, not slop:** "3 秒以内", a latency budget, a question count
  ("12 件" / "12 个问题") — never invented stats.

**Vibe in one line:** *a quiet instrument that does one anxious-making thing flawlessly and
tells you the truth about your data.*

---

## 3. Visual foundations

### Colour
- **Surfaces are obsidian.** The notch seam is **pure black `#000`** so it fuses with the
  hardware cutout; the app windows sit on **`#06070b`** (deep near-black with a breath of blue).
  Volume is never added by lightening the base — it comes from gradients, edges, and shadow.
- **Brand is a periwinkle**, `#7DA2FF`, used sparingly as the one saturated colour. It comes as a
  trio: `#A3BEFF` (top sheen of a convex key), `#7DA2FF` (body), `#5878E8` (grounded edge + the
  *colored* drop-shadow). The notch uses a marginally cooler `#78A0FF`.
- **`#CCDBFF` "sheen"** is a cool near-white — explicitly "the colour of screen-light on glass" —
  used for specular highlights, never as a fill.
- **Semantic:** record/destructive **red `#FF453A` / `#FF4F45`**, **warning orange `#FF9F1E`**.
  Red is reserved for the recording ring and destructive actions — it always means "live" or
  "danger".
- **Ink:** primary `#F5F6FB` / white@96%, secondary white@60%, tertiary white@34%. Text *on* an
  accent key is the deep `#0B0E18`.

### Typography
- **Apple system face**, set small and tight — this is instrument chrome, not a web page. SF Mono
  carries anything technical (API keys, latency, counts). The largest reading size is the notch
  answer at **15px**; kickers are 11px, tracked +1.5px, uppercase.

### Backgrounds
- **The aurora.** Onboarding + Settings sit on a "Living Metal" backdrop: a slow, deep,
  double-domain-warped fBm aurora in brand blues, brightest upper-centre (aligned with the real
  notch above the window) and falling to near-black under the reading column so type stays crisp.
  Recreated for the web as layered low-contrast radial pools (`.nm-aurora`) + dither.
- **No imagery, no photos, no illustration.** The brand has none. The only "image" is the app
  icon. Backgrounds are pure obsidian or the aurora.

### Materials, edges & shadows
- **Top-edge specular hairline.** Every raised surface carries a 0.75px hairline that is bright
  at the top and fades down — light falling from above. Borders use a gradient, not a flat stroke.
- **Grounded shadows, never glows.** Cards get a layered contact + ambient black shadow; the
  primary accent key gets a *colored* `#5878E8` glow that grounds it. There are **no blurry
  colored halos** anywhere.
- **The dither.** A fine triangular-PDF noise tile is laid additively over gradients at
  0.018–0.025 opacity to keep them glassy rather than stepped (`.nm-dither`). This is the single
  most important anti-banding / anti-slop device in the system.
- **Inner shadow** seats the notch under the menu bar (darken just below the seam).

### Corners
- **Continuous (squircle) radii**, always small: 6–11px for controls, 14px for floating cards,
  `0.235 × size` for the app icon. Surfaces are physically small, so corners are too.

### Motion
- **The whole product moves as one body.** A single morph time (~0.42s) is shared between a
  panel's frame animation and its content crossfade. Easing is an out-expo settle
  `cubic-bezier(0.22, 0.90, 0.24, 1.0)`; springs are **critically damped and re-targetable**
  mid-flight (click sidebar items fast and the selection pill chases without snapping).
- **Hover** = brighten +5% / lift fill opacity / a faint chip fades in. **Press** = scale to
  0.97 (0.94 for the tiny notch button) + dim. Never a hard color flip.
- **Restraint:** the one ambient animation is the finale button's light sweep, once every 3.6s —
  never a constant shimmer. Status motion (breathing dot, spinner, equalizer) runs on a display
  clock and crossfades between states so the notch never blinks.
- **Reduce Motion** jumps to end states (handled by tokens).

### Transparency & blur
- The expanded notch reserves a transparent margin so its shadow can fall without clipping the
  menu bar. Glass surfaces are dark fills with sheen + dither — **vibrancy/`backdrop-filter`
  blur is used sparingly**, mostly the material is *drawn*, not blurred.

---

## 4. Iconography

- **SF Symbols** is the app's icon system — Apple's variable, weight-matched symbol set, drawn as
  solid-tinted templates (`checkmark`, `exclamationmark`, `chevron.up.chevron.down`, `gear`,
  `mic`, `xmark`, etc.). They are **not** redistributable for the web.
- **Substitution (flagged):** this system uses **Lucide** (CDN) as the closest match — clean,
  rounded, ~1.5–2px stroke, semibold-equivalent weight. Components reference Lucide names; load it
  from `https://unpkg.com/lucide@latest`. If exact SF Symbols are needed, supply licensed assets.
- **Status jewel glyphs are bespoke**, not icons: a breathing dot (ready/listening), a sweeping
  arc spinner (thinking), a 3-bar equalizer (streaming), then a checkmark (presenting) / bang
  (error). These are drawn in code — recreated here in `components/notch/StatusJewel`.
- **Emoji** appear only as functional status glyphs (see §2). **Unicode** glyphs `·`, `・`, `⦿`,
  `⌘⇧` are used as typographic devices.
- **The logo / app icon** (`assets/notchmeet-icon-256.png`): a periwinkle continuous-squircle
  tile holding a black MacBook-notch silhouette with a single 4-point sparkle — the product's
  whole story (notch + AI) in one mark.

---

## 5. Index / manifest

**Root**
- `styles.css` — global entry point (imports only). Consumers link this.
- `readme.md` — this guide.
- `SKILL.md` — Agent-Skill front-matter for use in Claude Code.

**`tokens/`** (all reachable from `styles.css`)
- `colors.css` · `typography.css` · `spacing.css` · `motion.css` · `materials.css` · `base.css`

**`assets/`**
- `notchmeet-icon-256.png` — primary app icon · `notchmeet-appicon.png` · `notchmeet-favicon-64.png`

**`components/`** (React primitives — `.jsx` + `.d.ts` + `.prompt.md` + card)
- `core/` — `Button`, `Kicker`, `Badge`, `Card`
- `forms/` — `Toggle`, `Segmented`, `Field`, `Select`
- `notch/` — `StatusJewel`, `ProgressRail`

**`ui_kits/`** (full-screen product recreations)
- `notch/` — the collapsed + expanded notch in its live states
- `onboarding/` — the five-step welcome window
- `settings/` — the six-section settings window

**Foundation specimen cards** populate the Design System tab under groups
**Brand · Colors · Type · Spacing · Materials**.
