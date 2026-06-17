# Lístkomat — Top-bar theme customization

*Date: 2026-06-17 · Status: design validated, ready for implementation*

## Overview

Let the user personalize the app's **top bar** by picking from a small set of
tasteful, named **theme presets**. Each preset sets the bar color, the matching
text/icon color, and an optional emoji mascot — all in one tap. The motivation is
pure delight: Lístkomat is a fun / portfolio app, and the presets double as a
quiet roster of the people around it (Zajíc 🐰, his wife 🐸, his son 🐻, Slim 🐌,
plus Brno and USA).

Origin: feedback from Štěpán Lata ("Slim") — he'd accidentally downloaded the old
2016 build, which was letterboxed on his larger phone and left a **black bar at
the top that elegantly hid the Dynamic Island**. He liked that look and asked for
"a pink top bar with a unicorn." This feature gives that, natively and tastefully.

## What's customizable (and what isn't)

- **In scope (v1):** the app's top bar (fill color, text/icon color, emoji
  mascot) **and the app-wide accent** — the theme color flows into the city SVG
  icons, ticket prices, the active-ticket banner, the city picker grid, and
  button tints, so the whole app reads as one theme.
- **Out of scope (YAGNI):** full theming (page backgrounds, light/dark
  overrides), a free color picker, and theming the **Live Activity / lock-screen
  widget** (that would need an App Group to share the setting — a nice later
  extension, explicitly deferred).

## The top bar & the Dynamic Island

The header fills with a solid color that extends all the way to the **top edge of
the screen** (into the safe area / status-bar region), so the Dynamic Island sits
*inside* the colored band.

- **Black** preset → the Island goes black-on-black and visually disappears — the
  exact effect Štěpán liked from the old letterboxed build.
- **Pink** (and other light bands) → the Island stays visible as a black pill on
  the color (which reads as a deliberate, cute detail).

Contrast is handled for the user: each preset carries its own text/icon color, so
the result is never unreadable.

## Preset roster

Curated combos (not a free picker) so every choice looks intentional. Colors are
starting values — easy to tune. Two presets are named after people (a little
signature), two after places that matter to the dev.

| id     | Name  | Band / accent color | Text/icons | Mascot |
|--------|-------|---------------------|------------|--------|
| `black`| Černá | pure `#000000` | white | — (clean; Island vanishes) |
| `teal` | Teal (default) | `#56C4CF` (brand) | dark | 🚊 |
| `pink` | Růžová | `#FF7EB6` | dark | 🦄 |
| `zajic`| Zajíc | `#AFA79E` warm grey | dark | 🐰 (dev's surname = "hare") |
| `zaba` | Žába  | `#4CC76A` spring green | dark | 🐸 (dev's wife) |
| `meda` | Méďa  | `#8B5E3C` warm brown | white | 🐻 (dev's son) |
| `slim` | Slim  | `#74B84A` leaf green | dark | 🐌 (Štěpán "slimák"/snail) |
| `brno` | Brno  | `#C8102E` heraldic red | white | 🐉 (Brněnský drak) |
| `usa`  | USA   | `#3C3B6E` flag navy | white | 🇺🇸 (dev now lives in the US) |

`Černá` is listed first and uses **pure black** so the bar matches the page's
system-black text/icons exactly (no two-shades-of-black mismatch). The default at
first launch stays **Teal** regardless of list order. The band color doubles as
the app-wide accent.

The "keep it to ~5" guideline is intentionally and happily relaxed: these named,
personal themes *are* the charm of the feature — the dev (Zajíc 🐰), his wife
(🐸), his son (🐻), his friend Slim (🐌), and the two places that matter (Brno,
USA). Slim and Žába are deliberately different greens (leaf vs spring) so they
stay distinct; the emoji + name disambiguate regardless.

**Mascot = emoji, not custom art.** Colorful, scales at any size, zero
asset/licensing work, renders identically everywhere. It sits small on the
**leading** side next to the title. The mascot is part of the preset (no separate
mascot picker) — Black is deliberately mascot-free for the clean look.

## Interaction

- A small **gear icon on the trailing edge** of the top bar opens a **Theme**
  sheet. (Gear trailing, mascot leading, so they don't collide.)
- The sheet is a vertical list of preset rows: each shows the band color swatch,
  its mascot, the name, and a checkmark on the active one.
- Tapping a row applies it **live and instantly** — the top bar behind the sheet
  recolors as you browse, so you see the real thing (including Dynamic Island
  behavior) before committing. No Save button.

## Persistence

One line: `@AppStorage("themeId")` stores the chosen preset's `id` (e.g. `"pink"`),
defaulting to `"teal"`. Read at launch, applied to the top bar, survives
relaunches. A single string → nothing to migrate later.

## Architecture (minimal, no new dependencies)

```swift
struct Theme: Identifiable {
    let id: String          // "teal", "pink", …
    let name: String
    let band: Color
    let onBand: Color       // text/icon color for contrast
    let mascot: String?     // emoji, nil for Black
    static let presets: [Theme] = [ … ]   // the table above
    static func resolve(_ id: String) -> Theme  // id → Theme, falls back to teal
}
```

The top bar reads `@AppStorage("themeId")`, resolves it to a `Theme`, and styles
itself. No manager class needed.

## Versioning

Ships as a **v1.1** point release (bump `MARKETING_VERSION` 1.0 → 1.1 and
`CURRENT_PROJECT_VERSION`). Released via the now-automated pipeline
(`scripts/release.sh`).
