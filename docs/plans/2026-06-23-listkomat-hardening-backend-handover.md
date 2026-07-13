# Lístkomat — Hardening & Backend-Era Handover

*Date: 2026-06-23 · Status: HANDOVER — nothing here is built yet*

Pick-up brief for a fresh session. It captures what's shipped, what's left, and
the two tracks of remaining work. **This is a spec, not a plan** — when you start
a track, run `superpowers:writing-plans` (and `superpowers:brainstorming` first if
scope is fuzzy) to turn it into task-by-task TDD steps.

Source specs this consolidates:
- [Hardening & Polish design](2026-06-20-listkomat-hardening-polish-design.md) — §1/§2 shipped, §3 open.
- [v2 Live Map design](2026-06-18-listkomat-v2-live-map-design.md) — the Prague/proxy plan lives here.
- [LA timing plan](2026-06-20-listkomat-la-timing-plan.md) — where the backend APNs push was deferred.

---

## Where things stand (shipped in 2.0.1)

- **Live Activity timing** (hardening §1): validity anchored to `validFrom = sentAt + 120s`,
  pending → active phase, one-tap *Potvrdit nyní*, manual *Ukončit*. In-app banner
  buttons (Live Activities aren't interactive below iOS 17).
- **Brno map performance** (hardening §2): trimmed payload, bbox-bounded decode,
  capped/lightened annotations — fixed the first-open hang/OOM.
- **Client-only, no backend exists yet.** Only **Brno** has `hasLiveMap: true`.
  There is `BrnoVehicleSource`; there is **no** `PragueVehicleSource` and **no** server.

> Not released yet: a version footer (commit `3c13e1f`) sits on `main`, batched for
> the next release — don't cut a release just for it.

---

## Track A — Observability (client-only, can start now)

From hardening §3. Goal: know *if/when/why* the app crashes or hangs, without
betraying the "Data Not Collected" / zero-third-party-SDK ethos.

- **Baseline, no code (do this as a habit immediately):** Xcode → Organizer →
  **Crashes** gives symbolicated reports from opted-in App Store users (~1–2 day
  lag). "Check Organizer after each release" should be routine. For an urgent
  report, a friendly user can share Settings → Privacy & Security → Analytics &
  Improvements → **Analytics Data** (`Listkomat-*.ips` = code crash;
  `JetsamEvent-*` = memory kill).
- **App-side (MetricKit):** adopt `MXMetricManager` — Apple's built-in diagnostics
  delivering `MXCrashDiagnostic` / `MXHangDiagnostic` / `MXAppLaunchMetric` on next
  launch. **Registering the subscriber is client-only**; but *doing anything useful
  off-device with the payloads requires Track B* (a sink to POST to).
- **⚠️ Open decision (blocks the off-device half):** collecting diagnostics
  off-device likely forces adding "Crash Data / Diagnostics" to the App Store
  privacy label. Keeping "Data Not Collected" pristine means Organizer-only. **Decide
  before building the sink.** Explicitly avoid Sentry/Crashlytics.

**Smallest first step:** register a MetricKit subscriber that just logs locally
(no network) — proves the plumbing, changes no privacy label, and is ready to point
at a sink once Track B lands.

---

## Track B — The v2.1 backend (the linchpin)

Almost everything left routes through **one small serverless function**. Standing it
up unlocks three features at once. This is the big investment.

**B0 — The serverless proxy/backend itself.** A tiny function (host TBD). Needs a
public HTTPS endpoint, a place for one secret (the Golemio key), and short-TTL
caching. Design it as a small multi-purpose service, since B1–B3 all hang off it.

**B1 — Prague live map** (the headline feature; see the v2 design doc).
- Prague vehicles = **Golemio GTFS-RT** (protobuf), which **needs an API key** and
  has a **20 req / 8 s per-key** limit — a single embedded key shared by all users
  blows it instantly, hence the proxy: it holds the key and caches one upstream
  fetch to fan out to all clients.
- Build `PragueVehicleSource` (GTFS-RT decode via the proxy), mirroring
  `BrnoVehicleSource`'s shape and the same bbox/perf hardening from §2.
- Ship path: flip Prague's `hasLiveMap` in `listkomat-catalog` once code + proxy
  are live — **no app release needed** for the flip.

**B2 — MetricKit diagnostics sink** (finishes Track A's off-device half).
- POST the MetricKit payloads to an endpoint on the same proxy. Gated on the
  privacy-label decision above.

**B3 — Locked-screen push for pending → active** (deferred from the LA timing plan).
- Today the pending → active flip at `validFrom` only happens while the app is open
  (an in-app `TimelineView` ticks it). On a **locked** screen the Live Activity
  can't self-update at `validFrom`.
- Fix = an **APNs push** (ActivityKit push token → server → push at `validFrom`)
  to flip the label cleanly without the app foregrounded. Needs the proxy + APNs
  auth key + storing each activity's push token.

---

## Suggested sequencing

1. **Track A baseline now** — make Organizer-checking a release habit; land the
   local-only MetricKit subscriber. Zero backend, zero privacy-label risk.
2. **Decide the privacy-label question** — it gates B2 and the useful half of A.
3. **Track B** as a unit, because B1/B2/B3 share the proxy. **B1 (Prague map)** is
   the highest user value and the natural reason to build the server; B2 and B3
   ride along once it exists.

## Key files / touchpoints
- `Listkomat/Services/BrnoVehicleSource.swift` — template for `PragueVehicleSource`.
- `Listkomat/Services/VehicleSource.swift` — the source protocol.
- `Shared/TicketActivityAttributes.swift`, `Services/LiveActivityController.swift` —
  where B3's push-driven state flip lands.
- `Listkomat/Resources/tickets.json` + the `listkomat-catalog` repo — the
  `hasLiveMap` flip for Prague.
- Release via the existing CLI pipeline; keep the project habits: **write fresh
  "What's New"** (don't carry over) and **don't cancel a build in review**.
