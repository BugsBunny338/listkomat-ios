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

## Track A — Observability — RESOLVED 2026-07-12: a habit, not a feature

From hardening §3. Goal: know *if/when/why* the app crashes or hangs, without
betraying the "Data Not Collected" / zero-third-party-SDK ethos.

**Decision (2026-07-12):** for a hobby app with **no third-party SDKs and no
backend**, the honest best practice is **Xcode Organizer, and nothing else** — no
code this session. The reasoning:

- **Organizer already covers it, for free.** The **Crashes** tab gives
  symbolicated, grouped stack traces from opted-in users; the **Metrics** tab is
  *MetricKit-powered under the hood* (collected by Apple, no code) and shows hang
  rate, launch time, memory, disk, battery. That is everything a zero-code setup
  can produce, with **no privacy-label cost**. This directly serves the real goal:
  when a friend reports a crash, look in Organizer for it.
- **A custom `MXMetricManager` subscriber earns nothing right now.** Registering it
  is client-only, but with no backend to POST payloads to, the diagnostics just sit
  on the user's phone and never reach us. It's groundwork for a sink that doesn't
  exist — **YAGNI until Track B**. If/when Track B lands, revisit as **B2** below.
- **The breadcrumb gap is accepted.** The one thing Organizer lacks is the "what
  were they doing before the crash" trail; only crash-reporter SDKs or a custom
  backend give that, and both break "Data Not Collected." A stack trace is enough.
- **Privacy-label question is therefore moot for now** — we stay Organizer-only, so
  nothing forces a "Crash Data / Diagnostics" label. It only reopens if we ever
  build the B2 sink. Explicitly avoid Sentry/Crashlytics regardless.

**Outcome:** the Organizer habit is now written into the
[release checklist](../release-checklist.md) as a post-release step. No app code
changed. The MetricKit subscriber idea moves to Track B / B2 below.

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

**B2 — MetricKit diagnostics sink — DEFERRED INDEFINITELY 2026-07-12.**
- Would POST MetricKit payloads to an endpoint on the same proxy. But Track A
  resolved to **Organizer-only** to keep the "Data Not Collected" label pristine,
  so there's no sink to build. Only reopens if we ever decide off-device
  diagnostics are worth the privacy-label change — currently we've decided they're
  not. See the Track A section above.

**B3 — Locked-screen push for pending → active — DROPPED 2026-07-13 (already solved client-only).**
- ~~Today the flip only happens while the app is open; on a locked screen the Live
  Activity can't self-update.~~ **This premise was wrong.** It described the *in-app
  banner* (`ContentView.swift:159`, a `TimelineView` — app-open only) and missed the
  *widget's* separate mechanism.
- The locked-screen flip is **already implemented client-only**: `start()` sets
  `staleDate = validFrom` (`LiveActivityController.swift:45`), so iOS marks the
  activity stale and re-renders it on the locked screen at `validFrom` — riding the
  same system timeline that ticks the `Text(timerInterval:)` countdowns with no
  push. The widget gates `pending = !context.isStale`; `confirmNow()` sets
  `staleDate = now` for an instant flip. There's a ⚠️ in the code warning not to
  revert it.
- **No APNs push, token store, or scheduler needed.** Caveats: (1) the stale
  re-render has minor system slack — a push wouldn't be more precise, and even if it
  lags, only the "čeká" *label* lingers a few seconds while the countdowns stay
  correct; (2) confirm once on a **real locked device** (send ticket → lock → wait
  ~2 min → "čeká na potvrzovací SMS" should vanish at `validFrom`). Only revisit a
  push if that field check ever shows it flaky.

---

## Suggested sequencing (updated 2026-07-12/13)

Track A is **done** (Organizer habit → [release checklist](../release-checklist.md),
no code). B2 is deferred and B3 is dropped (see above). So Track B is now **just
B1**, and the only open build-work is:

1. **B1 — Prague live map.** The one remaining feature. It's the sole reason to
   stand up the proxy, and the proxy is a plain stateless cache (no token store, no
   scheduler, no APNs) now that B2/B3 are gone. Design it as its own plan when you
   start (`superpowers:writing-plans`). Open sub-decision to settle first: **have
   the proxy decode GTFS-RT server-side and return simple JSON** (keeps
   swift-protobuf out of the app, smaller payloads, `PragueVehicleSource` stays a
   trivial JSON decode like Brno) **vs. pass raw protobuf through** (app adds
   swift-protobuf). Server-side decode is the likely win for a hobby app.

## Key files / touchpoints
- `Listkomat/Services/BrnoVehicleSource.swift` — template for `PragueVehicleSource`.
- `Listkomat/Services/VehicleSource.swift` — the source protocol (yields `Vehicle`,
  now incl. `destinationId`).
- `Listkomat/Resources/tickets.json` + the `listkomat-catalog` repo — the
  `hasLiveMap` flip for Prague (no app release needed).
- Live Activity flip (B3) is already handled client-side in
  `Services/LiveActivityController.swift` + `ListkomatWidgets/TicketLiveActivity.swift`
  via `staleDate` — leave it alone.
- Release via the existing CLI pipeline; see the
  [release checklist](../release-checklist.md) for the habits (fresh "What's New",
  don't cancel in-review, check Organizer).
