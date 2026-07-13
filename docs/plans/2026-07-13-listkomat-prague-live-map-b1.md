# Prague Live Map (B1) Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add a live transit-vehicle map for Prague, mirroring the existing Brno map, fed through a tiny caching proxy that holds the Golemio API key.

**Architecture:** Golemio serves Prague vehicle positions as **GeoJSON** (verified live — *no protobuf, no `swift-protobuf`*). A stateless **Cloudflare Worker** holds the Golemio token, fetches the feed once per ~6 s, trims each vehicle to a compact JSON (`~717 KB → ~120 KB`), and fans that one cached fetch out to all app users — respecting Golemio's 20 req/8 s per-key limit. In the app, `PragueVehicleSource` decodes the Worker's JSON into the same `Vehicle` type the Brno map already renders, so the map is source-agnostic. Ship by flipping Prague's `hasLiveMap` in `listkomat-catalog` once the Worker is deployed — no app release.

**Tech Stack:** Cloudflare Workers (wrangler 4, plain JS), Swift/SwiftUI + MapKit (iOS 16.2), XCTest, xcodegen.

**Prereqs already settled:**
- Metro (`route_type` 1) **is included** → new `VehicleKind.metro`.
- Destination shown via a new `Vehicle.destinationName` (Prague fills it from `trip_headsign`; Brno leaves it `nil` and keeps its numeric `destinationId` path).
- Golemio token lives ONLY in the Worker secret + a local env file, never in the repo/app.

---

## Reference: verified feed facts (live 2026-07-13)

- Endpoint: `GET https://api.golemio.cz/v2/vehiclepositions?limit=5000`, header `X-Access-Token: <token>`. Returns GeoJSON `{features:[...]}`. HTTP 200.
- ~621 vehicles late evening (peak higher); full payload ~717 KB. All returned vehicles have `tracking=true`.
- Per-feature fields we use:
  - `geometry.coordinates` → `[lng, lat]`
  - `properties.last_position.bearing` (number, may be null defensively)
  - `properties.last_position.origin_timestamp` (ISO-8601 with tz)
  - `properties.trip.gtfs.trip_id` (stable id, present on all)
  - `properties.trip.gtfs.route_short_name` (line label: "10", "A", "S1", "100", "58")
  - `properties.trip.gtfs.route_type` (GTFS int)
  - `properties.trip.gtfs.trip_headsign` (destination text)
- **route_type distribution:** 3 bus (368), 0 tram (166), 2 rail (56), 1 metro (24), 11 trolleybus (7).
- **Wide bbox:** lng 12.9–15.9, lat 49.4–50.7 (regional trains + airport bus). The bbox guard must be generous.

### Real fixtures (one per type — use verbatim in tests)

| rt | id | lng,lat | brng | line | ts | dest |
|----|----|---------|------|------|----|------|
| 0 tram | `10_14927_260418` | 14.47317, 50.1045 | 354 | 10 | 2026-07-13T22:10:15+02:00 | Sídliště Ďáblice |
| 1 metro | `991_11435_260202` | 14.477781, 50.077774 | 293 | A | 2026-07-13T22:10:10+02:00 | Nemocnice Motol |
| 2 train | `1001_8650_251214` | 14.5441628, 50.09727 | 295 | S1 | 2026-07-13T22:09:46+02:00 | Praha Masarykovo nádraží |
| 3 bus | `100_867_250630` | 14.28761, 50.10538 | 340 | 100 | 2026-07-13T22:10:10+02:00 | Letiště / Airport ✈ |
| 11 trolley | `58_1837_250714` | 14.53095, 50.15118 | 335 | 58 | 2026-07-13T22:09:51+02:00 | Miškovice |

### The wire contract (Worker → app)

Compact JSON, short keys, `brng` nullable:
```json
{
  "ts": "2026-07-13T22:10:20+02:00",
  "vehicles": [
    {"id":"10_14927_260418","lat":50.1045,"lng":14.47317,"brng":354,"line":"10","rt":0,"ts":"2026-07-13T22:10:15+02:00","dest":"Sídliště Ďáblice"}
  ]
}
```

### route_type → VehicleKind (mapping owned by the app, unit-tested)

| route_type | VehicleKind |
|---|---|
| 0 | `.tram` |
| 1 | `.metro` |
| 2 | `.train` |
| 3 | `.bus` |
| 11 | `.trolleybus` |
| (other) | `.bus` |

---

## Task 1: Vehicle model — add `.metro` and `destinationName`

**Files:**
- Modify: `Listkomat/Models/Vehicle.swift`
- Modify: `Listkomat/Services/BrnoVehicleSource.swift:58-65` (pass `destinationName: nil`)
- Test: `ListkomatTests/VehicleModelTests.swift` (create)

**Step 1 — failing test** (`VehicleModelTests.swift`):
```swift
import XCTest
@testable import Listkomat

final class VehicleModelTests: XCTestCase {
    func testMetroKind() {
        XCTAssertEqual(VehicleKind.metro.czechName, "Metro")
        XCTAssertEqual(VehicleKind.allCases.count, 5)
    }
    func testDestinationNameCarried() {
        let v = Vehicle(id: "x", coordinate: .init(latitude: 50, longitude: 14),
                        bearing: nil, line: "A", kind: .metro,
                        updatedAt: Date(), destinationId: nil, destinationName: "Motol")
        XCTAssertEqual(v.destinationName, "Motol")
    }
}
```

**Step 2 — run, expect FAIL** (no `.metro`, no `destinationName`):
`xcodebuild test -scheme Listkomat -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:ListkomatTests/VehicleModelTests`

**Step 3 — implement** in `Vehicle.swift`:
- Add `case metro` to `VehicleKind` (order: `tram, metro, trolleybus, bus, train`).
- `czechName`: `.metro → "Metro"`.
- `color`: `.metro → Color(hex: 0xE0812B)` (amber; distinct from the other four).
- `displayName(brno:)` unchanged (metro only appears in Prague).
- Add stored property to `Vehicle`: `let destinationName: String?` (after `destinationId`). Leave `==` unchanged (identity + position + bearing only).

**Step 4 — fix the Brno call site** (`BrnoVehicleSource.swift`): add `destinationName: nil` to the `Vehicle(...)` init. Fix any other `Vehicle(...)` construction the compiler flags (e.g. existing tests).

**Step 5 — run, expect PASS.** Then run the whole `ListkomatTests` suite to confirm no regressions.

**Step 6 — commit:** `feat(map): VehicleKind.metro + Vehicle.destinationName (Prague prep)`

---

## Task 2: `PragueVehicleSource` — decode + mapping (TDD, no network)

Mirror `BrnoVehicleSource`'s shape: an `enum` of pure static functions, plus a thin `VehicleSource` struct (Task 4).

**Files:**
- Create: `Listkomat/Services/PragueVehicleSource.swift`
- Test: `ListkomatTests/PragueVehicleSourceTests.swift`
- Fixture: `ListkomatTests/Fixtures/prague-vehicles.json` (capture from the Worker in Task 5, or hand-build from the 5 rows above)

**Step 1 — failing tests:**
```swift
import XCTest
import CoreLocation
@testable import Listkomat

final class PragueVehicleSourceTests: XCTestCase {
    func testKindMapping() {
        XCTAssertEqual(PragueVehicleSource.kind(forRouteType: 0), .tram)
        XCTAssertEqual(PragueVehicleSource.kind(forRouteType: 1), .metro)
        XCTAssertEqual(PragueVehicleSource.kind(forRouteType: 2), .train)
        XCTAssertEqual(PragueVehicleSource.kind(forRouteType: 3), .bus)
        XCTAssertEqual(PragueVehicleSource.kind(forRouteType: 11), .trolleybus)
        XCTAssertEqual(PragueVehicleSource.kind(forRouteType: 99), .bus)
    }
    func testDecodeFixture() throws {
        let data = try fixture("prague-vehicles")
        let vs = try PragueVehicleSource.decode(data)   // no filters
        XCTAssertEqual(vs.count, 5)
        let metro = try XCTUnwrap(vs.first { $0.kind == .metro })
        XCTAssertEqual(metro.line, "A")
        XCTAssertEqual(metro.destinationName, "Nemocnice Motol")
        XCTAssertEqual(metro.coordinate.latitude, 50.077774, accuracy: 1e-6)
        XCTAssertEqual(metro.id, "991_11435_260202")
    }
    func testBboxAndFreshnessFilter() throws {
        let data = try fixture("prague-vehicles")
        // A generous box that still excludes a far-flung coordinate; and a tight
        // freshness window relative to the fixture timestamps drops everything.
        let now = ISO8601DateFormatter().date(from: "2026-07-13T22:10:20+02:00")!
        let fresh = try PragueVehicleSource.decode(data, bbox: .pragueArea,
                                                   fresherThan: 60, now: now)
        XCTAssertTrue(fresh.allSatisfy { $0.updatedAt >= now.addingTimeInterval(-60) })
    }
}
```
(Reuse the repo's existing `fixture(_:)` test helper if present — see `BrnoVehicleSourceTests`; otherwise add a small `Bundle(for:).url(forResource:withExtension:)` loader.)

**Step 2 — run, expect FAIL** (type doesn't exist).

**Step 3 — implement** `PragueVehicleSource.swift`:
```swift
import Foundation
import CoreLocation

/// Decoding for Prague's PID vehicle feed, delivered as compact JSON by the
/// Lístkomat proxy (which trims Golemio's GeoJSON). Pure static funcs so they're
/// unit-testable without the network. See docs/plans/2026-07-13-listkomat-prague-live-map-b1.md
enum PragueVehicleSource {
    private struct Payload: Decodable { let vehicles: [Wire] }
    private struct Wire: Decodable {
        let id: String; let lat: Double; let lng: Double
        let brng: Double?; let line: String; let rt: Int
        let ts: String; let dest: String?
    }

    struct BoundingBox {
        let minLat, maxLat, minLng, maxLng: Double
        func contains(lat: Double, lng: Double) -> Bool {
            lat >= minLat && lat <= maxLat && lng >= minLng && lng <= maxLng
        }
        /// Generous — PID includes regional trains + the airport bus, so a tight
        /// city box would drop legitimate vehicles. Guards only against garbage coords.
        static let pragueArea = BoundingBox(minLat: 49.4, maxLat: 50.8, minLng: 12.8, maxLng: 15.9)
    }

    static let freshnessLimit: TimeInterval = 180

    static func kind(forRouteType rt: Int) -> VehicleKind {
        switch rt {
        case 0: return .tram
        case 1: return .metro
        case 2: return .train
        case 11: return .trolleybus
        default: return .bus          // 3 and anything else
        }
    }

    static func decode(_ data: Data,
                       bbox: BoundingBox? = nil,
                       fresherThan: TimeInterval? = nil,
                       now: Date = Date()) throws -> [Vehicle] {
        let iso = ISO8601DateFormatter()
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        return payload.vehicles.compactMap { w -> Vehicle? in
            if let bbox, !bbox.contains(lat: w.lat, lng: w.lng) { return nil }
            let updated = iso.date(from: w.ts) ?? now
            if let fresherThan, now.timeIntervalSince(updated) > fresherThan { return nil }
            return Vehicle(
                id: w.id,
                coordinate: CLLocationCoordinate2D(latitude: w.lat, longitude: w.lng),
                bearing: (w.brng ?? -1) >= 0 ? w.brng : nil,
                line: w.line,
                kind: kind(forRouteType: w.rt),
                updatedAt: updated,
                destinationId: nil,
                destinationName: w.dest)
        }
    }
}
```

**Step 4 — run, expect PASS.**

**Step 5 — commit:** `feat(map): PragueVehicleSource decode + route_type mapping`

---

## Task 3: `PragueLiveSource` (VehicleSource conformance)

**Files:** modify `Listkomat/Services/PragueVehicleSource.swift`; test in the same file's test target (inject a stub `URLProtocol` or test the URL only — keep it light, matching how `BrnoLiveSource` is covered).

**Step 1 — implement** (append to `PragueVehicleSource.swift`):
```swift
/// Live Prague source: fetches the proxy's trimmed JSON and decodes it.
struct PragueLiveSource: VehicleSource {
    /// Proxy base, overridable for tests/staging. Default = production Worker.
    var endpoint: URL = URL(string: "https://listkomat-proxy.<subdomain>.workers.dev/prague/vehicles")!
    var session: URLSession = .shared

    func fetch() async throws -> [Vehicle] {
        var req = URLRequest(url: endpoint)
        req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let (data, _) = try await session.data(for: req)
        return try PragueVehicleSource.decode(data, bbox: .pragueArea,
                                              fresherThan: PragueVehicleSource.freshnessLimit)
    }
}
```
> Replace `<subdomain>` with the real workers.dev host after Task 5 deploy (or a custom domain). Keep the placeholder until then; it's the one spot to update post-deploy.

**Step 2 — commit:** `feat(map): PragueLiveSource fetches the proxy`

---

## Task 4: The Cloudflare Worker (the proxy)

**Files (new dir `proxy/`):**
- Create: `proxy/wrangler.toml`, `proxy/src/index.js`, `proxy/package.json`, `proxy/README.md`
- Create: `proxy/test/transform.test.mjs`
- Create: `proxy/.gitignore` (`node_modules`, `.dev.vars`, `.wrangler`)

**Step 1 — `proxy/src/index.js`** (pure `transform` + fetch handler):
```js
const GOLEMIO = "https://api.golemio.cz/v2/vehiclepositions?limit=5000";
const TTL = 6; // seconds; one upstream fetch fans out to all clients within a window

// Pure: Golemio GeoJSON -> compact wire object. Exported for unit tests.
export function transform(geojson, nowIso) {
  const vehicles = [];
  for (const f of geojson.features ?? []) {
    const p = f.properties ?? {};
    const g = p.trip?.gtfs ?? {};
    const lp = p.last_position ?? {};
    const c = f.geometry?.coordinates;
    if (!c || c.length !== 2 || g.trip_id == null) continue;
    vehicles.push({
      id: g.trip_id,
      lat: c[1], lng: c[0],
      brng: typeof lp.bearing === "number" ? lp.bearing : null,
      line: g.route_short_name ?? "",
      rt: g.route_type ?? 3,
      ts: lp.origin_timestamp ?? nowIso,
      dest: g.trip_headsign ?? null,
    });
  }
  return { ts: nowIso, vehicles };
}

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    if (url.pathname !== "/prague/vehicles") return new Response("Not found", { status: 404 });

    const cache = caches.default;
    const cacheKey = new Request(url.toString(), request);
    const hit = await cache.match(cacheKey);
    if (hit) return hit;

    let upstream;
    try {
      upstream = await fetch(GOLEMIO, { headers: { "X-Access-Token": env.GOLEMIO_TOKEN } });
    } catch {
      return json({ ts: new Date().toISOString(), vehicles: [] }, 502);
    }
    if (!upstream.ok) return json({ ts: new Date().toISOString(), vehicles: [] }, 502);

    const geo = await upstream.json();
    const body = transform(geo, new Date().toISOString());
    const res = json(body, 200, { "Cache-Control": `public, max-age=${TTL}` });
    ctx.waitUntil(cache.put(cacheKey, res.clone()));
    return res;
  },
};

function json(obj, status = 200, extra = {}) {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { "Content-Type": "application/json", "Access-Control-Allow-Origin": "*", ...extra },
  });
}
```
> `new Date().toISOString()` is fine at runtime in a Worker (only the *workflow* sandbox forbids it). Metro is intentionally NOT filtered.

**Step 2 — `proxy/wrangler.toml`:**
```toml
name = "listkomat-proxy"
main = "src/index.js"
compatibility_date = "2025-01-01"
# GOLEMIO_TOKEN is a secret: `wrangler secret put GOLEMIO_TOKEN` (never commit it).
```

**Step 3 — `proxy/package.json`:**
```json
{
  "name": "listkomat-proxy",
  "private": true,
  "type": "module",
  "scripts": {
    "dev": "wrangler dev",
    "deploy": "wrangler deploy",
    "test": "node --test"
  }
}
```

**Step 4 — `proxy/test/transform.test.mjs`** (pure, no network) using a captured Golemio GeoJSON fixture (`proxy/test/golemio-sample.json`, 5 features):
```js
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { transform } from "../src/index.js";

const geo = JSON.parse(readFileSync(new URL("./golemio-sample.json", import.meta.url)));

test("transform maps every feature to the wire shape", () => {
  const out = transform(geo, "2026-07-13T22:10:20+02:00");
  assert.equal(out.vehicles.length, 5);
  const metro = out.vehicles.find(v => v.rt === 1);
  assert.equal(metro.line, "A");
  assert.equal(metro.dest, "Nemocnice Motol");
  assert.equal(metro.lat, 50.077774);
});
test("drops features missing coords or trip_id", () => {
  const out = transform({ features: [{ geometry: null, properties: {} }] }, "t");
  assert.equal(out.vehicles.length, 0);
});
```
Run: `cd proxy && node --test` → expect PASS.

**Step 5 — local smoke test against live Golemio** (token via `.dev.vars`, gitignored):
```bash
cd proxy
printf 'GOLEMIO_TOKEN=%s\n' "$GOLEMIO_TOKEN" > .dev.vars   # from $CLAUDE_JOB_DIR/tmp/golemio.env
npx wrangler dev --port 8788 &
sleep 3
curl -s localhost:8788/prague/vehicles | head -c 400
# expect: {"ts":"...","vehicles":[{"id":...}]}  and a much smaller payload than 717 KB
```

**Step 6 — `proxy/README.md`** — deploy runbook (see "Deploy" section at the bottom of this plan).

**Step 7 — commit:** `feat(proxy): Cloudflare Worker caching + trimming Golemio Prague feed`

---

## Task 5: Prague stops (bundled, like Brno)

**Files:**
- Create: `scripts/generate-prague-stops.sh` (fetch `https://data.pid.cz/PID_GTFS.zip`, extract `stops.txt`, dedupe by `parent_station`, trim to `{id,name,lat,lon}`, write JSON)
- Create: `Listkomat/Resources/prague-stops.json`
- Modify: `Listkomat/Services/StopsStore.swift` → add `static func prague() -> [Stop]`

Follow the exact pattern of the Brno stops generator + `StopsStore.brno()`. Prague stop ids are strings (`Stop.id` is already `String`). No `stopNames` map needed for Prague (destinations come from `destinationName`).

**Test:** decode `prague-stops.json` → non-empty `[Stop]`, ids unique. Commit: `feat(map): bundle Prague PID stops`.

---

## Task 6: Wire city → source in the map

**Files:**
- Modify: `Listkomat/Services/LiveMapViewModel.swift` (inject source + stops; drop hardcoded Brno)
- Modify: `Listkomat/Views/LiveMapView.swift:7` (build the VM from `city`)

**Step 1 — make `LiveMapViewModel` injectable:**
```swift
init(source: VehicleSource, stops: [Stop], stopNames: [Int: String]) {
    self.source = source; self._seedStops = stops; self._seedStopNames = stopNames
}
```
Move the `StopsStore.brno()` / `StopNamesStore.brno()` defaults out of `start()` and into the seed passed at init.

**Step 2 — a city factory** (in `LiveMapViewModel` or a small helper):
```swift
static func make(for city: City) -> LiveMapViewModel {
    switch city.key {
    case "praha":
        return LiveMapViewModel(source: PragueLiveSource(),
                                stops: StopsStore.prague(), stopNames: [:])
    default: // "brno"
        return LiveMapViewModel(source: BrnoLiveSource(),
                                stops: StopsStore.brno(), stopNames: StopNamesStore.brno())
    }
}
```

**Step 3 — `LiveMapView`:** replace `@StateObject private var vm = LiveMapViewModel()` with a `@StateObject` initialized from `city` via `init(city:)` using `_vm = StateObject(wrappedValue: .make(for: city))`.

**Step 4 — test:** `LiveMapViewModel.make(for: pragueCity)` yields a VM whose stops are non-empty; `make(for: brnoCity)` still uses Brno. Manual: run the app in the simulator, force `hasLiveMap` on a Prague city, open the map, confirm Prague vehicles render (point `PragueLiveSource.endpoint` at `localhost:8788` from Task 4's `wrangler dev`).

**Step 5 — commit:** `feat(map): select vehicle source + stops by city (Prague/Brno)`

---

## Task 7: Prague data-source attribution (CC-BY)

**Files:** modify `Listkomat/Views/DataSourcesView.swift`.

Add the PID/Golemio attribution line, shown when the map city is Prague (CC-BY 4.0 requires attribution — the one hard license obligation):
- *"Vozidla a zastávky: Operátor ICT / Golemio (PID) — licence CC BY 4.0"* + link.

Commit: `feat(map): Prague data-source attribution`.

---

## Task 8 (POST-DEPLOY, separate repo): flip `hasLiveMap` for Prague

Only after the Worker is deployed and `PragueLiveSource.endpoint` points at the real host:
1. In `listkomat-catalog`, set Prague's `hasLiveMap: true` in `tickets.json`.
2. The app picks it up at runtime — **no app release needed.**
3. Verify on a real device: open Praha → Živá mapa → vehicles appear.

Also mirror the flag in `Listkomat/Resources/tickets.json` (the bundled fallback) if that's how the app seeds before first catalog fetch — check current behavior first.

---

## Deploy runbook (`proxy/README.md`)

The user runs these (needs their own Cloudflare account; free tier is fine):
```bash
cd proxy
npm i -g wrangler          # or use npx
wrangler login             # opens browser; authorize
wrangler secret put GOLEMIO_TOKEN   # paste the Golemio token (NOT committed)
wrangler deploy            # prints the https://listkomat-proxy.<subdomain>.workers.dev URL
```
Then update `PragueLiveSource.endpoint` (Task 3) with the printed URL and ship the app.

Rate-limit note: `Cache-Control max-age=6` means one Golemio fetch per ~6 s at the edge. Exceeding Golemio's 20 req/8 s would require >20 simultaneous cache misses in an 8 s window — implausible at hobby scale. If it ever matters, add a Durable Object single-flight; **not needed now (YAGNI)**.

---

## Order & checkpoints

1. Task 1 (model) → 2 (decode) → 3 (live source): pure Swift, TDD, fast.
2. Task 4 (Worker): build + local smoke test against live Golemio → **capture the real response as the Task 2/4 fixtures**.
3. Task 5 (stops) → 6 (wiring) → 7 (attribution).
4. Manual end-to-end in the simulator against `wrangler dev`.
5. Task 8 after the user deploys the Worker.

**Not in scope (YAGNI):** route lines, ETAs, search, B3 push (already solved via `staleDate`), B2 diagnostics.
