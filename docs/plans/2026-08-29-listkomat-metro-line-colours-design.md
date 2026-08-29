# Prague Metro Line Colours — Design

**Issue:** [#20](https://github.com/BugsBunny338/listkomat-ios/issues/20) — Prague metro
markers should use the official line colours (A green, B yellow, C red).
Folds in the ferry defect noticed while investigating (see *Ferries* below).

**Goal:** A metro pin on the live map is coloured by its line, using Prague's
conventional A-green / B-yellow / C-red, without any other vehicle kind being
mistaken for a metro line.

---

## Background

`VehicleKind.color` is a flat per-kind palette: every metro train is amber
`#E0812B` regardless of line, chosen in the B1 plan as "distinct from the other
four". That predates the map showing line letters. Today a C train and an A train
are indistinguishable, and the amber matches none of the three colours Praguers
actually navigate by.

The data is already there. The Prague feed carries the line letter directly —
a live sample taken 2026-08-29 returned 738 vehicles, of which `route_type` 1
(metro) numbered 30 across exactly three line values: `A`, `B`, `C`. The marker
already prints that letter as its glyph (`TransitMapView.style`). Nothing new
needs to be fetched or parsed.

Only three places read a vehicle's colour:

| Site | Use |
|---|---|
| `TransitMapView.swift:198` | `markerTintColor` on the map pin |
| `TransitMapView.swift:166` | `SelectedVehicle.color` for the bottom info card |
| `DataSourcesView.swift:16` | legend swatch |

## Decisions

**Metro leads, everything else recedes.** Prague publishes official colours only
for metro. Rather than invent equally loud colours for the other kinds and fight
them for attention, metro keeps full chroma and the remaining kinds sit at lower
chroma. Metro is 4% of pins but the network people orient by, so it earns the
salience.

**The glyph letter picks its own colour.** MapKit draws the glyph white by
default; white on the official yellow measures 1.49:1, which is unreadable. A
pure function picks black or white per fill, whichever contrasts better.

**The legend stays five rows** (six with ferry). The metro row carries three
lettered dots rather than splitting into three rows, which also means no new
localized strings for the metro lines.

## Palette

Metro — the official colours, unchanged from convention:

| Line | Fill | Glyph | Glyph contrast |
|---|---|---|---|
| A | `#00A05A` green | black | 6.18:1 |
| B | `#FFCE00` yellow | black | 14.08:1 |
| C | `#E1252B` red | white | 4.67:1 |

Recessive kinds — lower chroma, hues deliberately clear of metro's green/yellow/red:

| Kind | Fill | Glyph | Glyph contrast |
|---|---|---|---|
| Tram | `#D872A5` pink | black | 6.87:1 |
| Trolleybus | `#276F5D` deep teal | white | 5.97:1 |
| Ferry | `#03AED8` cyan | black | 8.05:1 |
| Bus | `#3F72C6` blue | white | 4.74:1 |
| Train | `#7E4587` violet | white | 6.80:1 |

Every fill clears 2.4:1 against both the light and the dark map background, and
every glyph pairing clears WCAG AA at 4.5:1.

These values were chosen by constrained search against the `dataviz` skill's
validator, not by eye — hand-designed candidates scored 2.7–5.5 on the
worst-pair colour-blindness test where the searched set scores 7.2. Ferry
takes cyan because it reads as water and because that arc is otherwise unused.

### Accessibility — what passes, what does not, and why

Reproduce with the `dataviz` skill's validator:

```sh
validate_palette.py "#00A05A,#FFCE00,#E1252B,#D872A5,#276F5D,#03AED8,#3F72C6,#7E4587" \
  --mode light --pairs all      # and again with --mode dark
```

- **Normal-vision floor: PASS at ΔE 15.4.** This is the check that asks whether
  a full-colour reader can tell any two pins apart, and the one the skill treats
  as a hard failure below 15. It passes with ferry included.
- **CVD separation: FAIL at ΔE 5.9**, entirely from metro A green ↔ metro C red
  under deuteranopia. Red-green is the classic confusion pair and it is inherent
  to Prague's official colours — fixing it means abandoning the premise of the
  issue. **Every metro pin always carries its letter**, so colour is never the
  sole channel; this is exactly the secondary encoding the guidance requires.
  Excluding the three immutable metro-vs-metro pairs, the worst separation
  across every remaining pair is 7.2 — inside the 6–8 band the guidance permits
  only alongside secondary encoding, which the labels provide.
- **Chroma floor: FAIL on trolleybus** (`#276F5D`, "reads gray"). That is the
  receding effect, working as designed.
- **Lightness band: FAIL on `#FFCE00`.** An official colour we do not control.
- **Contrast warnings** oblige "visible labels as relief" — every pin has one.

The honest summary: the only unresolved defect is one Prague itself has, and it
is mitigated the same way Prague mitigates it, with a letter.

## Ferries

Prague's feed carries `route_type` 4 — the Vltava ferries (*přívoz*), lines P5
and P6. `PragueVehicleSource.kind(forRouteType:)` has no case for 4, so they
fall through `default` and render as buses. This predates the issue and was not
in the original B1 feed sample (the 2026-07-13 distribution recorded no
`route_type` 4 at all), so it arrived with a later upstream change.

Folded in here because it lands in exactly the same files and the same palette
decision: fixing it after the fact would mean re-running the colour search and
re-validating everything.

Scope:

- New `VehicleKind.ferry`, mapped from Prague `route_type` 4 only.
- Czech name `Přívoz`, English `Ferry`, added to `Shared/Localizable.xcstrings`.
  `LocalizationTests` enforces the English translation exists.
- **Brno is untouched.** Brno's `VType` 4 is a regional bus — the dataset
  description claims `4 = ship`, but the codes were verified empirically against
  400 live messages and match the old semantics. `BrnoVehicleSourceTests`
  already asserts `kind(forVType: 4) == .bus`; that assertion stays and guards
  the change from leaking.
- The Brno legend filter must hide ferry as well as metro.

Ferries run seasonally and in daylight only: a sample at 20:19 on 2026-08-29
returned four P5/P6 vehicles, and a sample from the same evening returned none.
An empty ferry set is the normal night-time state, not a fault.

## Architecture

A new `Listkomat/Models/TransitPalette.swift` becomes the single source of truth
and `VehicleKind.color` is removed, so there is no second place for a colour to
drift:

```swift
struct MarkerStyle: Equatable {
    let fill: Color
    let glyph: Color
}

enum TransitPalette {
    /// Marker style for a vehicle. Only `.metro` consults `line`.
    static func style(for kind: VehicleKind, line: String) -> MarkerStyle
}
```

- `style` resolves metro `A`/`B`/`C` case-sensitively against the feed's values.
  Any other metro line value falls back to today's amber `#E0812B`, so a feed
  anomaly degrades to the current appearance rather than to an uncoloured pin.
- The glyph rule is a separate pure function on `Color` computing WCAG relative
  luminance and returning whichever of black/white contrasts better. It is
  reused by the legend, so a swatch and its pin can never disagree.
- The legend asks `TransitPalette` for the three metro styles directly rather
  than hardcoding them.

Call-site changes are mechanical: `style(view, kind, line)` sets both
`markerTintColor` and `glyphTintColor`; `SelectedVehicle.color` takes the
resolved fill; the legend's metro row renders three lettered dots.

## Testing

New `ListkomatTests/TransitPaletteTests.swift`:

- Each kind maps to its expected fill; metro A, B and C are mutually distinct.
- A metro vehicle on an unknown line falls back to amber.
- The glyph rule returns ≥4.5:1 contrast for all eight fills — the test computes
  the ratio rather than asserting a hardcoded black/white, so a future palette
  edit that breaks legibility fails the build.
- Non-metro kinds ignore `line` (same style for `"1"` and `"A"`).

Updated:

- `VehicleModelTests` — `allCases.count` 5 → 6.
- `PragueVehicleSourceTests` — `kind(forRouteType: 4) == .ferry`, and 99 still
  falls back to `.bus`.
- `BrnoVehicleSourceTests` — unchanged, deliberately: it pins `VType 4 == .bus`.

## Out of scope

- Per-line colours for anything but metro. Prague publishes none for tram or bus,
  and inventing them would undo the "metro leads" decision.
- Any change to the theme accent, which stops and chrome use.
- Re-examining Brno's `VType` mapping against the newer dataset description.
