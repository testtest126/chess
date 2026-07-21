# MateMate — Moodboard

*Agent-facing style reference. Skim, don't read straight through. Code is the
source of truth — this doc points at it rather than restating it, so it can't
drift out of sync.*

## Palette

**Source of truth is code, not this doc — and the app and the public site
use two genuinely different accent hues. This is not a copy error; verify
here before assuming one.**

| token | in-app (`Assets.xcassets`) | public site (`docs/index.html` `:root`) |
|---|---|---|
| background | `WarmBackground` → `#F6EFE2` light / `#171109` dark | `--bg` → `#F3F4EE` light / `#0F1512` dark |
| text / ink | *(none — system `.primary`/label color, not a custom token)* | `--ink` → `#1C231F` light / `#E8EBE3` dark |
| primary accent | `AccentColor` → `#8A6216` light / `#E7BA5C` dark (**gold/ochre**) | `--accent` → `#2C6E52` light / `#82CBA6` dark (**green**) |
| secondary/soft | — | `--buff` → `#E7D3A4` light / `#D9C186` dark (this is the site's gold) |

**If you were handed "mustard/ochre-gold primary, ink-black wordmark" for
this project** — that's accurate for the **app**, confirmed against
`AccentColor.colorset` and `screenshot-home.png` (gold capsule buttons, true
near-black bold wordmark rendered via the default SwiftUI `.navigationTitle`,
no custom "ink" color asset exists). It is **not** accurate for the
**public docs site** — its primary accent is a deep green (`--accent:
#2C6E52`), with the gold/buff tone demoted to a secondary token. Flag this
distinction rather than picking one and assuming it covers both surfaces.

### Board-theme swatches

Four presets, `BoardTheme.swift`, `UserDefaults` key `board_theme`:

| theme | light square | dark square |
|---|---|---|
| Classic | `#F0D9B5` | `#B58763` |
| Green | `#EDEDD1` | `#759657` |
| Blue | `#DEE6ED` | `#6B8CAD` |
| Gray | `#E0E0E0` | `#8C8C91` |

(Coordinate-label colors are separately tuned per theme for WCAG AA 4.5:1 —
see `coordinateColor(onLight:)` in the same file; don't reuse the swatch
colors above for text.)

## Typography & voice

- **Wordmark** — "MateMate", bold sans, large — but it's the **native**
  SwiftUI `.navigationTitle` (`HomeView.swift`, `GameView.swift`), not a
  custom logotype or graphic. Don't design a bespoke wordmark treatment;
  the system font *is* the brand here.
- **Controls** — native iOS SF-style throughout: system `Picker`,
  `SegmentedPickerStyle`-driven segmented controls, native
  `SignInWithAppleButton` (renders its own black pill — don't restyle it).
- **Microcopy** — short, plain, confident: "Play Online", "Start Game",
  "Recovers your account if you've played before." No exclamation points,
  no cuteness, no jargon.

## UI fragments

Grounded in `docs/screenshots/screenshot-home.png` and `HomeView.swift`:

- **Segmented pickers** — "Time control" (Bullet / Blitz / Rapid) and
  "Play as" (White / Black / Random), via a shared `AdaptiveSegmentedPicker`.
- **Gold pill primary buttons** — "Play Online", "Start Game": full-capsule,
  filled with `AccentColor` (the gold/ochre token above), white label.
- **Black Sign-in-with-Apple pill** — the stock Apple component, unmodified.
- **Board-theme swatches** — four small rounded squares (Classic/Green/
  Blue/Gray) in the Appearance section, selected value shown in gold.
- **Trophy icon** — SF Symbol `"trophy"` (`LeaderboardView.swift`), shown top
  trailing in a circular cream badge on Home.

## Tone words

classical · warm · clean · native · approachable · tournament-serious-but-friendly

## Do / Don't

| DO | DON'T |
|---|---|
| Warm neutrals (cream/parchment) as the base | Dark-mode-first design |
| Exactly one gold/ochre accent, in-app | Neon or saturated color outside the board themes |
| Native iOS patterns (`Picker`, system buttons, `SignInWithAppleButton`) | Heavy custom chrome that fights the system look |
| Multi-theme boards as the one place color plays | A second competing accent hue |

## Reference screenshots

Referenced (not duplicated) from `docs/screenshots/` and `docs/`:

- [`screenshot-home.png`](../../screenshots/screenshot-home.png) — Home:
  wordmark, both picker groups, gold pills, Sign in with Apple, board-theme
  swatches. The single best reference for this whole doc.
- [`screenshot-game.png`](../../screenshots/screenshot-game.png) — an
  in-progress board.
- [`screenshot-review.png`](../../screenshots/screenshot-review.png) —
  post-game review.
- [`app-icon.png`](../../app-icon.png) — the app icon.

## A note on "themes," two unrelated meanings

Don't conflate these — same word, two different systems:

- **In-app board themes** (what this doc covers): Classic / Green / Blue /
  Gray, `BoardTheme.swift`, applies to the chessboard only.
- **The-fleet page skins** (`docs/the-fleet/`, a documentation-site feature,
  unrelated to the app's design system): **six** named cultural themes —
  `arabic`, `japanese`, `indian`, `codex`, `andalus`, `terminal` — set via
  `data-theme` on the page root. If you were told only four (arabic/indian/
  andalus/terminal), that's incomplete; `japanese` and `codex` also exist.
  These style the making-of documentation pages, not MateMate itself, and
  have their own independent palettes per theme — not covered here.
