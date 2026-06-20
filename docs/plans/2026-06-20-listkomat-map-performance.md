# Map Performance & Memory Optimization — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Stop the v2.0 Brno live map from hanging/OOM-crashing on first open by cutting per-poll work at every stage (smaller payload, bounded decode, lighter annotations).

**Architecture:** The Brno KORDIS feed returns ~10,000 features region-wide and the app currently fetches `outFields=*` and decodes *all* of them every ~8 s, then drops ~300 vehicle + ~300 shadowed stop annotations onto `MKMapView`. We cut work three ways: (1) request only the 7 properties we decode, (2) drop out-of-Brno features *during decode* so we hold hundreds not 10k, (3) lighten the map layer (no per-marker shadow, lower stop cap, skip sub-pixel vehicle animations). Decode stays off-main (already `async`).

**Tech Stack:** Swift 6 / SwiftUI, MapKit (`UIViewRepresentable`), XCTest, XcodeGen. Implements §2 of `docs/plans/2026-06-20-listkomat-hardening-polish-design.md`.

**Working context:** This session works in place on `main` (no worktree). The `.xcodeproj` is XcodeGen-generated; run `xcodegen generate` before building if `project.yml` ever changes (it won't in this plan). Push to the personal account with the inline-token method (see project memory), only when asked.

**Test/build command (used throughout):**
```bash
cd /Users/bugsbunny/prj/listkomat
xcodebuild test -scheme Listkomat \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -sdk iphonesimulator -derivedDataPath /tmp/lk-dd \
  2>&1 | tail -40
```
To run a single test class, append `-only-testing:ListkomatTests/BrnoVehicleSourceTests`.

---

## Task 1: Trim the request payload to the fields we decode

The feed is GeoJSON, so geometry is always returned regardless of `outFields`; `outFields` only controls *properties*. We decode exactly 7 property fields (`ID, Bearing, LineName, VType, IsInactive, TimeUpdated, FinalStopID`). `TimeUpdated` must stay because `orderByFields` sorts on it. Requesting `*` ships every attribute (dozens) on every 8 s poll — wasted bandwidth and JSON-decode time.

**Files:**
- Modify: `Listkomat/Services/BrnoVehicleSource.swift` (`currentQueryURL`)
- Test: `ListkomatTests/BrnoVehicleSourceTests.swift`

**Step 1: Write the failing test**

Add to `BrnoVehicleSourceTests`:
```swift
func testQueryURLRequestsOnlyNeededFieldsNotStar() {
    let url = BrnoVehicleSource.currentQueryURL().absoluteString
    XCTAssertFalse(url.contains("outFields=*"), "should not request all fields")
    for field in ["ID", "Bearing", "LineName", "VType", "IsInactive", "TimeUpdated", "FinalStopID"] {
        XCTAssertTrue(url.contains(field), "missing required field \(field)")
    }
}
```

**Step 2: Run test to verify it fails**

Run the test command with `-only-testing:ListkomatTests/BrnoVehicleSourceTests/testQueryURLRequestsOnlyNeededFieldsNotStar`.
Expected: FAIL (URL currently contains `outFields=*`).

**Step 3: Write minimal implementation**

In `currentQueryURL`, replace the `outFields=*` portion. The field list is URL-safe (commas → `%2C`):
```swift
let fields = "ID%2CBearing%2CLineName%2CVType%2CIsInactive%2CTimeUpdated%2CFinalStopID"
return URL(string: "\(base)?where=1%3D1&outFields=\(fields)&orderByFields=TimeUpdated%20DESC&f=geojson")!
```

**Step 4: Run test to verify it passes**

Run the same `-only-testing` command. Expected: PASS. Also re-run the whole `BrnoVehicleSourceTests` class to confirm `testLayerNameRollsOverByYear` etc. still pass.

**Step 5: Commit**
```bash
git add Listkomat/Services/BrnoVehicleSource.swift ListkomatTests/BrnoVehicleSourceTests.swift
git commit -m "perf(map): request only the 7 used fields, not outFields=*"
```

---

## Task 2: Bound the decoded set to a generous Brno bounding box

The feed covers all of South Moravia (~10k vehicles). The map only ever shows the Brno area, so decode should drop out-of-area features before building `Vehicle`s — keeping memory in the hundreds and shrinking every downstream per-poll cost. Keep `BrnoVehicleSource` MapKit-free (it's pure/unit-testable), so define a tiny local bbox struct rather than using `MKCoordinateRegion`.

Brno center is `49.195, 16.607`. Use a generous metro box (±~0.25° lat ≈ 28 km, ±~0.34° lng) as a single named constant that's trivial to widen later.

**Files:**
- Modify: `Listkomat/Services/BrnoVehicleSource.swift` (add `BoundingBox`, `brnoArea`, bbox param on `decode`, pass it in `BrnoLiveSource.fetch`)
- Test: `ListkomatTests/BrnoVehicleSourceTests.swift`

**Step 1: Write the failing test**

The existing `fixture` has an active bus at `49.4798, 16.6012` (near Brno) — keep that passing. Add a feature far outside (e.g. Prague `50.08, 14.43`) and assert it's dropped when a bbox is supplied, but kept when no bbox is supplied (backward compatibility for the existing one-arg `decode`).
```swift
func testDecodeDropsFeaturesOutsideBoundingBox() throws {
    let withFaraway = """
    {"type":"FeatureCollection","features":[
      {"geometry":{"type":"Point","coordinates":[16.6012,49.4798]},"properties":
        {"LineName":"258","Bearing":225,"TimeUpdated":1767776798912,"IsInactive":"false","VType":4,"ID":21856}},
      {"geometry":{"type":"Point","coordinates":[14.4378,50.0755]},"properties":
        {"LineName":"22","Bearing":10,"TimeUpdated":1767776798912,"IsInactive":"false","VType":0,"ID":99999}}
    ]}
    """
    let bounded = try BrnoVehicleSource.decode(Data(withFaraway.utf8), bbox: .brnoArea)
    XCTAssertEqual(bounded.map(\.id), ["21856"])           // Prague tram dropped

    let unbounded = try BrnoVehicleSource.decode(Data(withFaraway.utf8))
    XCTAssertEqual(unbounded.count, 2)                     // no bbox → keep both
}

func testBrnoAreaContainsCityCenter() {
    XCTAssertTrue(BrnoVehicleSource.BoundingBox.brnoArea.contains(lat: 49.195, lng: 16.607))
    XCTAssertFalse(BrnoVehicleSource.BoundingBox.brnoArea.contains(lat: 50.075, lng: 14.437))
}
```

**Step 2: Run test to verify it fails**

Run both new tests. Expected: FAIL to **compile** (`decode(_:bbox:)` and `BoundingBox` don't exist yet) — a compile failure is an acceptable red.

**Step 3: Write minimal implementation**

In `BrnoVehicleSource`, add the bbox type + constant:
```swift
/// A lat/lng rectangle. MapKit-free so the decoder stays pure/unit-testable.
struct BoundingBox {
    let minLat, maxLat, minLng, maxLng: Double
    func contains(lat: Double, lng: Double) -> Bool {
        lat >= minLat && lat <= maxLat && lng >= minLng && lng <= maxLng
    }
    /// Generous Brno metro box (~±28 km). Widen here if vehicles vanish on pan-out.
    static let brnoArea = BoundingBox(minLat: 48.95, maxLat: 49.45, minLng: 16.25, maxLng: 16.95)
}
```
Add a defaulted `bbox` parameter to `decode` and apply it in the `compactMap` guard (default `nil` keeps the existing one-arg call sites and tests working):
```swift
static func decode(_ data: Data, bbox: BoundingBox? = nil) throws -> [Vehicle] {
    let fc = try JSONDecoder().decode(FeatureCollection.self, from: data)
    return fc.features.compactMap { f -> Vehicle? in
        guard f.properties.IsInactive != "true",
              f.geometry.coordinates.count == 2 else { return nil }
        let lng = f.geometry.coordinates[0], lat = f.geometry.coordinates[1]
        if let bbox, !bbox.contains(lat: lat, lng: lng) { return nil }
        return Vehicle(
            id: String(f.properties.ID),
            coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lng),
            bearing: f.properties.Bearing >= 0 ? f.properties.Bearing : nil,
            line: f.properties.LineName,
            kind: kind(forVType: f.properties.VType),
            updatedAt: Date(timeIntervalSince1970: f.properties.TimeUpdated / 1000),
            destinationId: (f.properties.FinalStopID ?? 0) > 0 ? f.properties.FinalStopID : nil)
    }
}
```
Then make the live source actually bound its results:
```swift
func fetch() async throws -> [Vehicle] {
    var req = URLRequest(url: BrnoVehicleSource.currentQueryURL())
    req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    let (data, _) = try await session.data(for: req)
    return try BrnoVehicleSource.decode(data, bbox: .brnoArea)
}
```

**Step 4: Run test to verify it passes**

Run the full `BrnoVehicleSourceTests` class. Expected: all PASS (new bbox tests + all pre-existing tests, since one-arg `decode` is unchanged in behavior).

**Step 5: Commit**
```bash
git add Listkomat/Services/BrnoVehicleSource.swift ListkomatTests/BrnoVehicleSourceTests.swift
git commit -m "perf(map): bound decode to a Brno bbox (10k features -> hundreds)"
```

---

## Task 3: Lighten map annotations

View-layer work (`MKMapView` / `MKAnnotationView`) — not unit-testable, so the gate is a clean build + the visual/Instruments check in Task 4. Three cheap wins, smallest-risk first:

1. **Drop the per-stop drop-shadow.** A `layer.shadow*` on each of ~150–300 `StopMarkerView`s forces offscreen rendering — a classic scroll/pan hitch. Replace with a flat border (the ring already provides contrast).
2. **Lower the stop cap** below the vehicle cap (stops are context, not the feature). Give stops their own `stopCap = 150`, leave vehicles at `cap = 300`.
3. **Skip sub-pixel vehicle animations.** `UIView.animate` on up to 300 annotations every poll, even for vehicles that barely moved, is wasteful. Only animate when the coordinate moved meaningfully (~>5 m).

**Files:**
- Modify: `Listkomat/Views/TransitMapView.swift`

**Step 1: Drop the stop shadow**

In `StopMarkerView.init`, delete the four `dot.layer.shadow*` lines. (Optional: bump `dot.layer.borderWidth` to keep the dot crisp without the shadow.)

**Step 2: Separate + lower the stop cap**

In `Coordinator`, add `private let stopCap = 150` next to `private let cap = 300`. In `refreshStops`, change `.prefix(cap)` → `.prefix(stopCap)`.

**Step 3: Only animate meaningful vehicle moves**

In `syncVehicles`, for the existing-annotation branch, compute the move distance and skip the `UIView.animate` for tiny deltas (set the coordinate directly):
```swift
if let a = vehicleAnn[v.id] {
    a.apply(v); a.destination = destination(v)
    let moved = abs(a.coordinate.latitude  - v.coordinate.latitude)  > 0.00005
             || abs(a.coordinate.longitude - v.coordinate.longitude) > 0.00005
    if moved {
        UIView.animate(withDuration: 0.9) { a.coordinate = v.coordinate }
    } else {
        a.coordinate = v.coordinate
    }
    if let view = map.view(for: a) as? MKMarkerAnnotationView { style(view, v.kind, v.line) }
}
```

**Step 4: Build (with tests) to verify it compiles and nothing regressed**

Run the full test command. Expected: BUILD SUCCEEDED, all tests PASS (no test touches these view internals, so green = no compile/behaviour break).

**Step 5: Commit**
```bash
git add Listkomat/Views/TransitMapView.swift
git commit -m "perf(map): drop stop shadows, lower stop cap, skip sub-pixel animations"
```

---

## Task 4: Verify on an OLD device profile (not just a new one)

The audience skews to older iPhones, so verifying on a fast simulator can hide the very hang we're fixing. This is a manual verification step, not a commit.

**Step 1: Launch the live map on an older simulator**

Boot an older model (e.g. **iPhone SE (3rd gen)** if its runtime is installed; otherwise the oldest available) and open Brno → "Živá mapa".
```bash
xcrun simctl list devices available | grep -iE "SE|iPhone 1[12]"
```
Run via the XcodeBuildMCP tools (preferred per project memory) or `xcodebuild ... build` + `simctl install/launch`.

**Step 2: Observe first-open behavior**

Confirm the reported failure mode is gone: tiles + vehicles appear together, the UI stays tappable (no multi-second freeze), and it does not crash on first/second open.

**Step 3: Profile with Instruments**

Attach **Time Profiler + Allocations + Hangs**. Targets to confirm:
- No main-thread hang > 250 ms on first open.
- Peak memory well below prior (bounded `vehicles` should be hundreds, not 10k).
- Per-poll CPU noticeably lower (trimmed payload + bounded decode).

**Step 4: Cross-check against Štěpán's crash log when it arrives (~2026-06-21)**

If the `.ips` / `JetsamEvent` log confirms an OOM/main-thread hang, note that these changes target exactly that. If it shows a *different* cause (e.g. a logic crash), open a follow-up — these optimizations still stand.

---

## Sequencing & ship

Tasks 1–3 are independent client-only changes; do them in order, commit each. After Task 4 verification looks good, this becomes the bulk of **2.0.1**:
- Bump `CURRENT_PROJECT_VERSION` (+ `MARKETING_VERSION` to 2.0.1) in `project.yml`, `xcodegen generate`.
- Refresh **What's New** deliberately (don't carry over — project habit) — e.g. "Plynulejší a stabilnější živá mapa."
- Ship via `scripts/release.sh`; don't cancel the build once in review (project habit).
- §1 (Live Activity timing) from the hardening design can ride the same 2.0.1 or follow — decide at ship time.
