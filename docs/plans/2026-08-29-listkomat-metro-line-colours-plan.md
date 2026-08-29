# Prague Metro Line Colours Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Colour Prague metro markers by line (A green, B yellow, C red) instead of one flat amber, and give the Vltava ferries their own vehicle kind instead of rendering them as buses.

**Architecture:** A new `TransitPalette` enum becomes the single source of truth for marker colour, replacing `VehicleKind.color`. Only `.metro` consults the line letter; every other kind returns one lower-chroma colour. A pure `Color.readableGlyph` rule picks black or white for the glyph letter, because MapKit's default white is unreadable on the official yellow. Three call sites consume it: the map pin, the bottom info card and the legend.

**Tech Stack:** Swift 5 / SwiftUI, MapKit, XCTest, xcodegen.

**Design spec:** `docs/plans/2026-08-29-listkomat-metro-line-colours-design.md` — read it before starting; it records why the palette values are what they are and which accessibility checks deliberately fail.

## Global Constraints

- iOS deployment target **16.2**, Swift 5 language mode.
- The Xcode project is **generated and gitignored**. Run `xcodegen generate` after adding any new file, or the build will not see it. Never hand-edit `Listkomat.xcodeproj`.
- Target sources are directory globs (`sources: [Listkomat, Shared]`), so new files under `Listkomat/` need no `project.yml` change — only the regenerate.
- Build: `xcodebuild -scheme Listkomat -destination 'generic/platform=iOS Simulator' build`
- Test: `xcodebuild -scheme Listkomat -destination 'platform=iOS Simulator,name=iPhone 17' test` (verified present on this machine; re-check with `xcrun simctl list devices available | grep iPhone` if it fails).
- App UI language is Czech; code, comments and commit messages are English.
- User-visible strings live in `Shared/Localizable.xcstrings` with a Czech key and an English translation. `LocalizationTests` fails the build if a translatable key has no `en` value.
- **Brno's `VType 4` is a regional bus and must stay `.bus`.** Only Prague's `route_type 4` becomes ferry.

---

### Task 1: Add the ferry vehicle kind

Prague's feed carries `route_type` 4 (Vltava ferries, lines P5/P6). There is no case for it, so ferries fall through `default` and render as buses.

**Files:**
- Modify: `Listkomat/Models/Vehicle.swift:6` (enum cases), `:10-17` (`localizedName`), `:25-33` (`color`)
- Modify: `Listkomat/Services/PragueVehicleSource.swift:37-44`
- Modify: `Shared/Localizable.xcstrings`
- Test: `ListkomatTests/VehicleModelTests.swift:7`, `ListkomatTests/PragueVehicleSourceTests.swift:20-27`

**Interfaces:**
- Consumes: nothing.
- Produces: `VehicleKind.ferry`; `PragueVehicleSource.kind(forRouteType: 4) == .ferry`. Task 2 relies on `.ferry` existing as a case.

- [ ] **Step 1: Write the failing tests**

In `ListkomatTests/PragueVehicleSourceTests.swift`, add one line inside `testKindMapping()`, after the `route_type 3` assertion:

```swift
        XCTAssertEqual(PragueVehicleSource.kind(forRouteType: 4), .ferry)
```

In `ListkomatTests/VehicleModelTests.swift`, change the count in `testMetroKind()` from 5 to 6:

```swift
        XCTAssertEqual(VehicleKind.allCases.count, 6)
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild -scheme Listkomat -destination 'platform=iOS Simulator,name=iPhone 17' test`
Expected: compile failure — `type 'VehicleKind' has no member 'ferry'`.

- [ ] **Step 3: Add the case, its name and its colour**

In `Listkomat/Models/Vehicle.swift`, change the case list:

```swift
    case tram, metro, trolleybus, bus, train, ferry
```

Add to `localizedName`, after the `.train` line:

```swift
        case .ferry: return String(localized: "Přívoz")
```

Add to `color`, after the `.train` line (this colour is temporary only in the sense that Task 3 moves it — the value is final):

```swift
        case .ferry: return Color(hex: 0x03AED8)        // cyan (Prague ferries)
```

- [ ] **Step 4: Map Prague's route_type 4**

In `Listkomat/Services/PragueVehicleSource.swift`, add a case to `kind(forRouteType:)` between `case 2` and `case 11`:

```swift
        case 4: return .ferry
```

The `default: return .bus` line stays — `route_type` 3 and any future code still fall back to bus.

- [ ] **Step 5: Add the English translation**

`Shared/Localizable.xcstrings` is JSON. Edit it with this script rather than by hand:

```bash
python3 - <<'EOF'
import json
from collections import OrderedDict

p = 'Shared/Localizable.xcstrings'
d = json.load(open(p), object_pairs_hook=OrderedDict)

entry = OrderedDict([('localizations', OrderedDict([
    ('en', OrderedDict([('stringUnit', OrderedDict([
        ('state', 'translated'), ('value', 'Ferry')]))]))]))])

# Insert after "Potvrdit nyní", where Czech collation puts it (Po... < Př...).
# Preserving key order keeps the diff to the one inserted entry.
out = OrderedDict()
for k, v in d['strings'].items():
    out[k] = v
    if k == 'Potvrdit nyní':
        out['Přívoz'] = entry
d['strings'] = out

with open(p, 'w') as f:
    json.dump(d, f, ensure_ascii=False, indent=2, separators=(',', ' : '))
    f.write('\n')
EOF
```

Do not use `json.dump`'s default separators or `sort_keys=True` — they
re-serialize the whole catalog in a different style from Xcode's own
(`"key": value` instead of `"key" : value`, plus alphabetical reordering),
producing an unreviewable ~700-line diff for a one-key addition and
guaranteeing Xcode rewrites the file again on its next save. The ordered
insertion plus `separators=(',', ' : ')` above keeps the diff to the
inserted entry only.

- [ ] **Step 6: Run the tests to verify they pass**

Run: `xcodebuild -scheme Listkomat -destination 'platform=iOS Simulator,name=iPhone 17' test`
Expected: PASS. `BrnoVehicleSourceTests.testVTypeMapping` must still pass — it asserts `kind(forVType: 4) == .bus`, which proves the change did not leak into Brno.

- [ ] **Step 7: Commit**

```bash
git add Listkomat/Models/Vehicle.swift Listkomat/Services/PragueVehicleSource.swift \
        Shared/Localizable.xcstrings ListkomatTests/VehicleModelTests.swift \
        ListkomatTests/PragueVehicleSourceTests.swift
git commit -m "Add ferry vehicle kind for Prague route_type 4

The Vltava ferries (P5/P6) fell through to .bus and rendered as buses.
Brno's VType 4 is a regional bus and is deliberately unchanged.

Refs #20"
```

---

### Task 2: TransitPalette and the glyph contrast rule

**Files:**
- Create: `Listkomat/Models/TransitPalette.swift`
- Test: `ListkomatTests/TransitPaletteTests.swift`

**Interfaces:**
- Consumes: `VehicleKind` including `.ferry` (Task 1).
- Produces:
  - `struct MarkerStyle: Equatable { let fill: Color; let glyph: Color }`
  - `TransitPalette.style(for kind: VehicleKind, line: String) -> MarkerStyle`
  - `TransitPalette.fill(for kind: VehicleKind, line: String) -> Color`
  - `Color.readableGlyph -> Color`, `Color.relativeLuminance -> Double`, `Color.contrastRatio(_:_:) -> Double`
  - Task 3 calls `style` (map pin), `fill` (info card) and both (legend).

- [ ] **Step 1: Write the failing test**

Create `ListkomatTests/TransitPaletteTests.swift`:

```swift
import XCTest
import SwiftUI
@testable import Listkomat

final class TransitPaletteTests: XCTestCase {

    // MARK: Metro is coloured per line

    func testMetroLinesUseTheOfficialColours() {
        XCTAssertEqual(TransitPalette.fill(for: .metro, line: "A").rgbHex, 0x00A05A)
        XCTAssertEqual(TransitPalette.fill(for: .metro, line: "B").rgbHex, 0xFFCE00)
        XCTAssertEqual(TransitPalette.fill(for: .metro, line: "C").rgbHex, 0xE1252B)
    }

    func testMetroLinesAreMutuallyDistinct() {
        let fills = ["A", "B", "C"].map { TransitPalette.fill(for: .metro, line: $0).rgbHex }
        XCTAssertEqual(Set(fills).count, 3)
    }

    /// A feed anomaly must degrade to the pre-2.4 amber, never to an uncoloured pin.
    func testUnknownMetroLineFallsBackToAmber() {
        XCTAssertEqual(TransitPalette.fill(for: .metro, line: "D").rgbHex, 0xE0812B)
        XCTAssertEqual(TransitPalette.fill(for: .metro, line: "").rgbHex, 0xE0812B)
        XCTAssertEqual(TransitPalette.fill(for: .metro, line: "a").rgbHex, 0xE0812B)
    }

    // MARK: Every other kind ignores the line

    func testNonMetroKindsIgnoreTheLine() {
        for kind in VehicleKind.allCases where kind != .metro {
            XCTAssertEqual(TransitPalette.fill(for: kind, line: "1").rgbHex,
                           TransitPalette.fill(for: kind, line: "A").rgbHex,
                           "\(kind) must not depend on the line")
        }
    }

    func testRecessiveKindsAreMutuallyDistinct() {
        let kinds = VehicleKind.allCases.filter { $0 != .metro }
        let fills = kinds.map { TransitPalette.fill(for: $0, line: "1").rgbHex }
        XCTAssertEqual(Set(fills).count, kinds.count)
    }

    // MARK: The glyph letter stays legible

    /// MapKit draws the glyph white by default, which measures 1.49:1 on the
    /// official metro yellow. Every fill must pair with a glyph at WCAG AA.
    func testEveryGlyphPairingMeetsWCAGAA() {
        var fills = ["A", "B", "C"].map { TransitPalette.style(for: .metro, line: $0) }
        fills += VehicleKind.allCases.filter { $0 != .metro }
            .map { TransitPalette.style(for: $0, line: "1") }

        for style in fills {
            let ratio = Color.contrastRatio(style.fill.relativeLuminance,
                                            style.glyph.relativeLuminance)
            XCTAssertGreaterThanOrEqual(
                ratio, 4.5,
                "fill \(String(format: "%06X", style.fill.rgbHex)) fails AA at \(ratio)")
        }
    }

    func testGlyphPicksTheHigherContrastInk() {
        // Yellow is the case that motivated the rule.
        XCTAssertEqual(TransitPalette.style(for: .metro, line: "B").glyph.rgbHex, 0x000000)
        // Red keeps the conventional white letter.
        XCTAssertEqual(TransitPalette.style(for: .metro, line: "C").glyph.rgbHex, 0xFFFFFF)
    }

    func testRelativeLuminanceEndpoints() {
        XCTAssertEqual(Color.white.relativeLuminance, 1.0, accuracy: 0.001)
        XCTAssertEqual(Color.black.relativeLuminance, 0.0, accuracy: 0.001)
        XCTAssertEqual(Color.contrastRatio(1.0, 0.0), 21.0, accuracy: 0.01)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodebuild -scheme Listkomat -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:ListkomatTests/TransitPaletteTests`
Expected: compile failure — `cannot find 'TransitPalette' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Listkomat/Models/TransitPalette.swift`:

```swift
import SwiftUI

/// Fill and glyph colour for one live-map marker.
struct MarkerStyle: Equatable {
    let fill: Color
    let glyph: Color
}

/// Single source of truth for live-map marker colours.
///
/// Prague's metro lines carry conventional colours riders navigate by — A green,
/// B yellow, C red — so metro is coloured per line. Every other kind gets one
/// lower-chroma colour, chosen so nothing competes with a metro line.
///
/// The values were picked by constrained search against a contrast and
/// colour-blindness validator, not by eye: hand-designed candidates scored 2.7–5.5
/// on the worst-pair CVD test where this set scores 7.2, and the set clears the
/// normal-vision floor at ΔE 15.4. Metro A green vs C red is inherently
/// red-green (ΔE 5.9 under deuteranopia) and cannot be fixed while keeping the
/// official colours — the always-present line letter is the mitigation.
///
/// See docs/plans/2026-08-29-listkomat-metro-line-colours-design.md before editing.
enum TransitPalette {

    // Official Prague metro line colours.
    static let metroA = Color(hex: 0x00A05A)   // green
    static let metroB = Color(hex: 0xFFCE00)   // yellow
    static let metroC = Color(hex: 0xE1252B)   // red

    /// Metro on a line we don't recognize. Deliberately the pre-2.4 amber, so a
    /// feed anomaly degrades to the old appearance rather than to a wrong line colour.
    static let metroUnknown = Color(hex: 0xE0812B)

    /// Marker fill. Only `.metro` consults `line`.
    static func fill(for kind: VehicleKind, line: String) -> Color {
        switch kind {
        case .metro:
            switch line {
            case "A": return metroA
            case "B": return metroB
            case "C": return metroC
            default:  return metroUnknown
            }
        case .tram:       return Color(hex: 0xD872A5)   // pink
        case .trolleybus: return Color(hex: 0x276F5D)   // deep teal
        case .ferry:      return Color(hex: 0x03AED8)   // cyan — reads as water
        case .bus:        return Color(hex: 0x3F72C6)   // blue
        case .train:      return Color(hex: 0x7E4587)   // violet
        }
    }

    /// Fill plus the ink the line letter should be drawn in.
    static func style(for kind: VehicleKind, line: String) -> MarkerStyle {
        let fill = fill(for: kind, line: line)
        return MarkerStyle(fill: fill, glyph: fill.readableGlyph)
    }
}

extension Color {
    /// Black or white — whichever has more contrast against this colour.
    ///
    /// MapKit draws marker glyphs white by default, which measures 1.49:1 on the
    /// official metro yellow and is effectively unreadable.
    var readableGlyph: Color {
        let l = relativeLuminance
        return Self.contrastRatio(l, 1.0) >= Self.contrastRatio(l, 0.0) ? .white : .black
    }

    /// WCAG 2.1 relative luminance. Returns 0 for any colour UIKit can't express
    /// as RGB, which makes `readableGlyph` fall back to a white glyph.
    var relativeLuminance: Double {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a) else { return 0 }
        func channel(_ v: CGFloat) -> Double {
            let v = Double(v)
            return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)
    }

    /// WCAG contrast ratio between two relative luminances.
    static func contrastRatio(_ l1: Double, _ l2: Double) -> Double {
        let hi = max(l1, l2), lo = min(l1, l2)
        return (hi + 0.05) / (lo + 0.05)
    }
}
```

Note the `switch kind` has no `default`, so adding a seventh vehicle kind later fails the build here instead of silently picking a wrong colour.

- [ ] **Step 4: Regenerate the project so the new file is compiled**

Run: `xcodegen generate`

- [ ] **Step 5: Run the tests to verify they pass**

Run: `xcodebuild -scheme Listkomat -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:ListkomatTests/TransitPaletteTests`
Expected: PASS, all 8 tests.

- [ ] **Step 6: Commit**

```bash
git add Listkomat/Models/TransitPalette.swift ListkomatTests/TransitPaletteTests.swift
git commit -m "Add TransitPalette with per-line metro colours and a glyph contrast rule

Not yet wired to the map; VehicleKind.color is still in use.

Refs #20"
```

---

### Task 3: Wire the palette into the map, the info card and the legend

**Files:**
- Modify: `Listkomat/Views/TransitMapView.swift:166` (info card), `:197-204` (`style`)
- Modify: `Listkomat/Views/DataSourcesView.swift:12-20` (legend)
- Modify: `Listkomat/Models/Vehicle.swift:25-33` (delete `color`)

**Interfaces:**
- Consumes: `TransitPalette.style(for:line:)`, `TransitPalette.fill(for:line:)`, `MarkerStyle` (Task 2).
- Produces: nothing further — this is the last task.

- [ ] **Step 1: Colour the map pin by line**

In `Listkomat/Views/TransitMapView.swift`, replace the body of `style(_:_:_:)`:

```swift
        private func style(_ view: MKMarkerAnnotationView, _ kind: VehicleKind, _ line: String) {
            let marker = TransitPalette.style(for: kind, line: line)
            view.markerTintColor = UIColor(marker.fill)
            view.glyphTintColor = UIColor(marker.glyph)
            view.glyphText = line
            view.titleVisibility = .hidden        // no floating label; number stays in the bubble
            view.subtitleVisibility = .hidden
            view.canShowCallout = false           // tap shows the SwiftUI bottom card instead
            view.displayPriority = .required
        }
```

- [ ] **Step 2: Colour the bottom info card by line**

In the same file, in `mapView(_:didSelect:)`, replace the `color:` argument:

```swift
                                     color: TransitPalette.fill(for: v.kind, line: v.line)))
```

- [ ] **Step 3: Give the legend a three-dot metro row**

In `Listkomat/Views/DataSourcesView.swift`, replace the `Section("Legenda")` vehicle-kind loop (the `ForEach` over `VehicleKind.allCases` and its `HStack`) with:

```swift
                Section("Legenda") {
                    // Metro and the Vltava ferries are Prague-only; hide both from Brno's legend.
                    ForEach(VehicleKind.allCases.filter {
                        brno ? ($0 != .metro && $0 != .ferry) : true
                    }, id: \.self) { kind in
                        HStack(spacing: 12) {
                            legendSwatch(kind)
                            Text(kind.displayName(brno: brno))
                            Spacer()
                        }
                    }
```

Then add this helper inside `DataSourcesView`, after `body`:

```swift
    /// Metro shows one lettered dot per line; every other kind shows a single dot.
    /// Both sit in the same fixed width so the labels line up.
    @ViewBuilder
    private func legendSwatch(_ kind: VehicleKind) -> some View {
        HStack(spacing: 4) {
            if kind == .metro {
                ForEach(["A", "B", "C"], id: \.self) { line in
                    metroDot(line)
                }
            } else {
                Circle()
                    .fill(TransitPalette.fill(for: kind, line: ""))
                    .frame(width: 16, height: 16)
            }
        }
        .frame(width: 56, alignment: .leading)   // 3 × 16 + 2 × 4, so rows align
    }

    /// One metro line's swatch: its colour, with its letter in the readable ink.
    private func metroDot(_ line: String) -> some View {
        let style = TransitPalette.style(for: .metro, line: line)
        return ZStack {
            Circle().fill(style.fill)
            Text(line)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(style.glyph)
        }
        .frame(width: 16, height: 16)
    }
```

The stop row below it keeps its own `HStack`; leave it untouched.

- [ ] **Step 4: Delete the old palette**

In `Listkomat/Models/Vehicle.swift`, delete the whole `color` computed property (the `/// Marker color — distinct, refined transit palette.` comment and the `var color: Color { ... }` block). `TransitPalette` is now the only source of marker colour.

- [ ] **Step 5: Build to prove there are no remaining callers**

Run: `xcodebuild -scheme Listkomat -destination 'generic/platform=iOS Simulator' build`
Expected: BUILD SUCCEEDED. A failure here names any call site still reading `kind.color` — fix it to use `TransitPalette` rather than restoring the property.

- [ ] **Step 6: Run the full test suite**

Run: `xcodebuild -scheme Listkomat -destination 'platform=iOS Simulator,name=iPhone 17' test`
Expected: PASS, including `LocalizationTests` (proves the `Přívoz` → `Ferry` entry from Task 1 is well-formed) and `BrnoVehicleSourceTests` (proves Brno's `VType 4` is still a bus).

- [ ] **Step 7: Look at it**

Numbers do not catch layout problems. Build to a simulator, open Prague's live map, and check:

- Metro pins show A green, B yellow, C red, each with a readable letter — the yellow B in particular must have a dark letter.
- The legend's metro row shows three lettered dots and its label lines up with the rows above and below.
- Switch the simulator to dark appearance and confirm the pins are still legible against the dark map.
- Prague's ferries only run in daylight; an empty ferry set at night is expected, not a bug. To see one, either check during service hours or trust the unit test.

Prefer the XcodeBuildMCP tooling for launching and screenshotting over hand-rolled `xcodebuild` invocations.

- [ ] **Step 8: Commit**

```bash
git add Listkomat/Views/TransitMapView.swift Listkomat/Views/DataSourcesView.swift \
        Listkomat/Models/Vehicle.swift
git commit -m "Colour Prague metro markers by line

Map pins, the bottom info card and the legend all resolve colour through
TransitPalette; VehicleKind.color is gone. The legend's metro row shows
three lettered dots, and Brno hides both metro and ferry.

Closes #20"
```

---

## Self-review notes

Checked against the design spec:

- Per-line metro colour → Task 2 (`fill`), Task 3 (call sites).
- Glyph contrast rule → Task 2 (`readableGlyph`), applied in Task 3 Step 1 via `glyphTintColor`.
- Unknown-line amber fallback → Task 2, tested.
- Five-row legend with three lettered dots → Task 3 Step 3.
- `VehicleKind.color` removed, single source of truth → Task 3 Step 4, enforced by the build in Step 5.
- Ferry kind, Prague-only, localized → Task 1; Brno guarded by the existing `BrnoVehicleSourceTests` assertion, re-run in Task 3 Step 6.
- Test list from the spec → all present in Task 2's test file plus the two amended tests in Task 1.
