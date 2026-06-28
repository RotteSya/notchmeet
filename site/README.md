# notchmeet — landing page

A static, production implementation of the `notchmeet Landing` design (exported from Claude
Design). Single page, Chinese UI, obsidian + edge-of-light material system.

## Run

No build step. Serve the folder with any static server:

```bash
cd site
python3 -m http.server 8000   # → http://localhost:8000
```

Opening `index.html` over `file://` works too, but a server is recommended (the WebGL aurora
and Lucide CDN behave best over http).

## Structure

```
site/
  index.html              # the page (semantic markup, inline styles per the design)
  css/
    design-system.css     # notchmeet DS tokens + material/helper classes (.nm-card, .nm-dither …)
    landing.css           # page styles, keyframes, notch transitions, convex-key buttons
  js/
    aurora.js             # the "Living Metal" WebGL fBm aurora shader (unchanged from the design)
    app.js                # notch state machine, scroll wake/standby, reveals, parallax, waitlist, clock
  assets/
    notchmeet-icon-256.png
```

## What it does

- **Interactive notch** fused to the menu bar: auto-cycles a demo (standby → listening →
  thinking → streaming → presenting), collapses to standby on scroll, wakes at the top, flares
  outward at the top corners when expanded. Click it to skip to the next question.
- **WebGL aurora** behind the hero, with pointer parallax; falls back to a CSS gradient if WebGL
  is unavailable.
- Sections: Hero → 三个瞬间 → 体验 (MacBook theater + two answer paths) → 隐私 (data flow) →
  费用 (hosted plan + email/LINE waitlist) → final CTA → footer.
- **Waitlist**: email/LINE toggle, validation, persists to `localStorage`, shows a success state
  on return.

## Configuration — drop in real values

All wiring placeholders live in one `CONFIG` block at the top of **`js/app.js`**:

| Key | Default | Purpose |
| --- | --- | --- |
| `DOWNLOAD_URL` | `"#"` | The macOS app download (e.g. a signed `.dmg`). While `"#"`, the final CTA is a scroll-to-top placeholder; set a URL and it becomes a real download link. |
| `WAITLIST_ENDPOINT` | `null` | A URL that accepts `POST {mode, contact}`. While `null`, the waitlist is local-only (`localStorage`). Set it to also forward submissions. |
| `AURORA_INTENSITY` | `1` | Aurora master brightness, `0.4`–`1.0`. |
| `DEMO_AUTOPLAY` | `true` | `false` holds the notch on a single presented answer (calm mode). |

## Notes

- **Icons**: Lucide is loaded from `unpkg.com` at runtime (per the design system, which
  substitutes Lucide for Apple's SF Symbols). Self-host it if you want to drop the CDN dependency.
- **Fonts**: the Apple system stack (`-apple-system` → SF Pro on Apple hardware), as the brand
  intends. No webfont ships.
- **Language**: Chinese UI only (the Japanese UI toggle was removed during design). The interview
  Q&A inside the notch stays Japanese — that's the product's actual output, not a UI language.
