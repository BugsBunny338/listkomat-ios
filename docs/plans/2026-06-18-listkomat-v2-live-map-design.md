# Lístkomat v2 — Live transit map

*Date: 2026-06-18 · Status: design validated, ready for implementation*

## Overview

A full-screen map showing **live vehicle positions** (trams / trolleybuses /
buses) plus **stops**, for the city you're viewing. This is the feature the 2016
app had (Brno only). Its strategic value: unlike the SMS tickets, the map **works
for everyone regardless of SIM**, so it's the tourist-facing half of the app.

**v2.0 ships Brno only** (zero backend, keyless feed). **Prague is v2.1** — it
needs a caching proxy (see end). The other 8 Czech cities have no usable open
real-time data, so the map is a Brno+Prague feature, surfaced only where it works.

## Data sources (verified live 2026-06-18, all CC-BY 4.0)

| Data | Brno (v2.0) | Prague (v2.1) |
|---|---|---|
| **Live vehicles** | KORDIS ArcGIS FeatureServer, **keyless**, GeoJSON, ~10 s refresh | Golemio GTFS-RT protobuf, **needs key + proxy** |
| **Stops** | ArcGIS stops layer, keyless (10.8k platform rows) | static GTFS zip `data.pid.cz/PID_GTFS.zip` → stops.txt (19k) |

- **Brno vehicles:** `https://gis.brno.cz/ags1/rest/services/Hosted/Kordis_26_polohy/FeatureServer/0/query?where=1=1&outFields=*&f=geojson`. Fields: `ID, Lat, Lng, Bearing, LineName, RouteID, TimeUpdated, IsInactive` + vehicle-type. ⚠️ The `_26_` is the **year and rolls over annually** — resolve the current layer from the stable dataset item (`e8aa121910df41bb9a28e4ca34a263c7`) on open, cache it; fall back to `Kordis_<yy>_polohy`. Poll the FeatureServer (their WebSocket stream is broken).
- **Brno stops:** `https://services6.arcgis.com/fUWVlHWZNxUvTUh8/arcgis/rest/services/stops/FeatureServer/0` (keyless; **no rollover** — stable). Static, so **bundled** (below).
- **License:** both CC-BY 4.0, commercial/app use and redistribution explicitly allowed. Only obligation = **attribution**.

## Licensing / attribution (the one hard requirement)

A "Zdroje dat" (Data sources) screen, reachable from an ⓘ button on the map:
- *"Vozidla a zastávky: Magistrát města Brna (data.Brno) / KORDIS JMK — licence CC BY 4.0"* + link to the CC-BY 4.0 license.
- (v2.1 adds the PID/Praha line.)

No license forbids commercial apps or key embedding; the only Prague concern is the rate limit (handled by the proxy, v2.1).

## Architecture & components

**Vehicle source abstraction** (so Prague slots in later unchanged):
```swift
protocol VehicleSource { func fetch() async throws -> [Vehicle] }

struct Vehicle: Identifiable {
    let id: String
    let coordinate: CLLocationCoordinate2D
    let bearing: Double?
    let line: String          // "12", "P6"
    let kind: VehicleKind     // tram / trolleybus / bus
    let updatedAt: Date
}
```
`BrnoVehicleSource` decodes the ArcGIS GeoJSON → `[Vehicle]` and resolves the
annual layer URL. v2.1's `PragueVehicleSource` (GTFS-RT via proxy) yields the same
`Vehicle`, so the map is source-agnostic.

**Stops (static, bundled):**
```swift
struct Stop: Identifiable { let id: String; let name: String; let coordinate: CLLocationCoordinate2D }
```
A build-time script fetches the Brno stops layer, **dedupes by `parent_station`**
(10.8k platform rows → ~physical stations), trims to `{id,name,lat,lon}`, and writes
`Resources/brno-stops.json` shipped in the binary. `StopsStore` decodes it once.
Refreshed occasionally on app updates (documented regen script, like the catalog).

**Map rendering:** `MKMapView` wrapped in a `UIViewRepresentable` (keeps the iOS
16.2 floor; full annotation control). `LiveMapViewModel` (ObservableObject) owns
the source + stops, runs the poll loop, publishes `[Vehicle]`.

**Entry point:** a remote-catalog `hasLiveMap` flag (Brno = true) drives a labeled
**"Živá mapa"** button on the ticket screen. Tap → **push** `LiveMapView` onto the
existing NavigationStack (themed bar + back; map fills the rest, **portrait**).

**Dependencies:** none for Brno — `URLSession` + `Codable` + MapKit, all built-in.

## Map UX

- **Vehicle markers:** rounded badge with the **line number**, tinted by `kind`
  (tram / trolley / bus), with a bearing notch. Tap → callout: line +
  "aktualizováno před Xs".
- **Stops:** a quiet small marker, visually distinct from vehicles, shown **only
  when zoomed in** past a threshold (thousands of stops would be noise at city
  zoom). Tap → stop name.
- **Refresh loop:** resolve layer URL, fetch, then poll ~**8 s**; **animate**
  vehicles from old→new coordinate so they glide. **Pause** on view-disappear and
  app-background; resume on return.
- **Performance:** filter to the **visible region** and cap on-screen count;
  dequeue/reuse annotation views; pan/zoom re-filters from the last fetch without a
  network call.
- **Framing:** default-center on Brno; if location permission is already granted
  and the user is near Brno, center on them. A recenter button.

## Error / empty states

- **Feed unreachable** → keep last-known positions, show a small non-blocking
  banner ("Živá data dočasně nedostupná"), retry next cycle. Never blank.
- **No vehicles** → quiet "Žádná vozidla v okolí" overlay.
- **Layer-resolution failure** → fall back to year-computed URL, then an error
  state with retry.
- **Stale/inactive** → drop `IsInactive` vehicles; fade any not updated recently.
- **Stops** can't fail at runtime (bundled).

## Testing

- Unit tests on **captured fixtures** (no network): ArcGIS vehicle GeoJSON →
  `[Vehicle]` (count/fields, `kind` mapping, bearing); `Kordis_<yy>` layer/year
  logic; bundled stops JSON decode + parent_station dedupe. Run in CI with the
  existing tests.
- MapKit view itself: verified manually in the simulator with the fixtures + a
  live run.

## Scope guard (YAGNI — v2.0 excludes)

- **Brno only.** Prague is v2.1.
- Live vehicles + stops only — **no** route lines, search, ETAs, or schedule data.
- No clustering beyond region-filter + cap.
- **Portrait only**; no offline cache of vehicle positions (live by nature).

## Prague — v2.1 (the fast-follow)

Prague needs work v2.0 doesn't:
1. **GTFS-RT protobuf** decoding → add **swift-protobuf** (first real dependency).
2. **A caching proxy.** Golemio's limit is **20 req / 8 s per key**; one embedded
   key shared by all users blows it instantly. A tiny serverless function fetches
   Golemio once per interval and serves the cached feed to all app users (one
   upstream fetch, many downstream). This is new infrastructure — pick a host
   (e.g. Cloudflare Worker) when we get there.
3. Stops: extract `stops.txt` from `data.pid.cz/PID_GTFS.zip`, same bundling.
4. Performance: Prague has far more vehicles than Brno — region-filter is essential.

Flip Prague's catalog `hasLiveMap` on once the code + proxy exist; no app release
needed to surface it.

## Shipping

v2.0 ships through the existing CLI pipeline (`scripts/release.sh` after a version
bump; the new-version App Store record + "What's New" via the ASC API, as in 1.1).
