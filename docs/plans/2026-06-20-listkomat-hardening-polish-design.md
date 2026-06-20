# Lístkomat — Hardening & Polish (design)

*Date: 2026-06-20 · Status: DESIGN ONLY — implementation deferred to a future session*

Three independent workstreams from real-user feedback on the live 2.0 release.
Likely lands as **2.0.1** (timing + map optimization) plus an **observability**
track that partly starts now and partly rides with the v2.1 backend.

> **For the implementer:** this is a spec, not a plan. When picking it up, run
> superpowers:writing-plans to turn each section into task-by-task TDD steps.
> Nothing here is built yet.

---

## 1. Live Activity timing — ticket validity vs SMS send

**Problem (Eva K., 2026-06-20):** the Live Activity countdown starts the instant
the SMS is *sent*, but the ticket is only valid from the operator's *confirmation
SMS* (~2 min later). Apple gives no SMS-delivery callback, so we can't anchor
exactly. The under-appreciated risk is the **start** of the window: the app shows
"valid" immediately, but a fare check in the first ~2 min could mean a fine.

**Design (agreed with Jiří):**
- **Default 2-minute activation buffer.** On `.sent`, the ticket enters a
  **"čeká na potvrzení"** (pending) phase; the validity countdown is anchored to
  **send + 120 s**, not send. So `validFrom = sentAt + 120s`.
- **Pending UI.** During the pending phase, the Live Activity + the in-app
  active-ticket banner show "Aktivuje se… (čeká na potvrzovací SMS)" with a short
  note that validity begins at the confirmation SMS. After `validFrom`, it flips
  to the normal time-left countdown.
- **"Potvrdit nyní" (confirm sooner).** A one-tap action that re-anchors
  `validFrom = now` — for when the user's confirmation SMS arrives before the 2
  min are up. Sets the countdown live immediately.
- **"Ukončit" (already shipped).** Manual cancel stays — covers a failed send
  (e.g. lost signal in the metro; `.sent` ≠ delivered).

**Implementation notes:**
- `Shared/TicketActivityAttributes.swift` `ContentState` needs `validFrom: Date`
  (and a derived `isPending` = `now < validFrom`). The widget's
  `Text(timerInterval: validFrom...validFrom+duration)` only counts the active
  window; before `validFrom` render the pending label.
- `Services/LiveActivityController.swift`: `start()` sets `validFrom = sent + 120s`;
  add `confirmNow()` (re-anchor to now) and keep `stop()`.
- **iOS 16.2 floor caveat:** Live Activities aren't interactive until iOS 17
  (App Intents). So "Potvrdit nyní" / "Ukončit" live as **in-app banner buttons**
  (tap the activity → app → confirm/end), like the current Ukončit. Optionally,
  iOS 17+ gets real in-activity buttons as progressive enhancement.
- The buffer (120 s) should be a single named constant, easy to tune.

---

## 2. Map performance & memory optimization

**Problem (Štěpán L., 2026-06-20):** on first opens the map showed vehicle
numbers but no tiles, then froze (couldn't tap), and reportedly crashed ~twice
before working on the 3rd try — on a **new** iPhone (so older target phones, the
real audience, are likely worse). Symptoms = first-load **main-thread hang and/or
memory spike** (possible JetsamEvent OOM). Optimize regardless of the eventual log.

**Root inefficiency:** the Brno feed returns **10,000 features** (server-side
`where`/`geometry` filters are ignored), and the app currently fetches
`outFields=*` and decodes **all 10,000** every ~8 s, keeps them all in
`@Published vehicles`, then filters to the visible region + caps at 300 — plus it
drops ~300 vehicle + ~300 custom stop annotations onto MKMapView while tiles load.

**Design — cut the work at every stage:**
1. **Trim the payload.** Request only the ~9 fields used:
   `ID,Lat,Lng,Bearing,LineName,VType,IsInactive,TimeUpdated,FinalStopID`
   (not `*`). Smaller download, faster JSON decode. (`BrnoVehicleSource.currentQueryURL`)
2. **Bound the decoded set.** Filter to a generous **Brno bounding box** during
   decode so the app holds *hundreds*, not 10,000 (`BrnoVehicleSource.decode`
   takes a bbox; drop out-of-box features before building `Vehicle`s). Cuts
   memory + every downstream per-poll cost. (Prague later: its own bbox.)
3. **Keep heavy work off the main thread.** Decode already runs off-main (the
   `nonisolated async` source) — preserve that. Ensure `updateUIView`/`syncVehicles`
   only ever touches the small bounded set, never 10k. If region-filtering ever
   gets heavy, move it off-main and hand the view a ready array.
4. **Lighten annotations.** ~300 custom `StopMarkerView`s each with a shadow layer
   + label is costly. Options: lower the stop cap (e.g. 150), drop the per-marker
   shadow, and/or only animate vehicles whose coordinate moved meaningfully
   (skip sub-pixel moves) instead of `UIView.animate` on all 300 each poll.
5. **Stagger first load.** Consider showing tiles/vehicles first, then adding
   stops a beat later (or on first idle) so the initial frame isn't one big spike.
6. **Memory hygiene.** Don't retain the raw 10k `Data`/parsed array longer than
   needed; bounded `vehicles` only.

**Verification (when implemented):** profile with **Instruments** (Time Profiler,
Allocations, Hangs) on the **oldest supported device/simulator** (iPhone SE / an
older model), not just a new one — the audience skews old. Watch for main-thread
hangs > 250 ms and peak memory on first open.

---

## 3. Observability — crash/hang visibility, now and ongoing

**Goal:** know *if, when, and why* the app crashes/hangs for users, without
betraying the app's "Data Not Collected" / zero-third-party-SDK ethos.

- **Now / baseline (no code, no privacy-label change):** Xcode → Window →
  **Organizer → Crashes** — symbolicated reports from opted-in users on App Store
  builds (lands within ~1–2 days). Make "check Organizer after each release" a
  habit. For an immediate report, have a friendly user share
  Settings → Privacy & Security → Analytics & Improvements → **Analytics Data**
  (`Listkomat-*.ips` = code crash; **`JetsamEvent-*`** = memory kill).
- **Ongoing, app-side (with the v2.1 backend):** adopt **MetricKit**
  (`MXMetricManager`) — Apple's built-in diagnostics; on next launch it delivers
  `MXCrashDiagnostic`, `MXHangDiagnostic`, and `MXAppLaunchMetric`. POST those
  payloads to **our own endpoint** (the Prague caching proxy / serverless fn can
  double as a diagnostics sink). No third-party SDK.
  - ⚠️ **Privacy-label decision:** collecting diagnostics *off-device* likely
    means adding "Crash Data / Diagnostics" to the App Store privacy nutrition
    label. If we'd rather keep "Data Not Collected" pristine, stay with Organizer
    only. Decide at implementation time.
- **Explicitly avoid** Sentry/Crashlytics (adds a dependency and clearly collects
  data — against this app's ethos).

---

## Sequencing
- **2.0.1:** §1 (timing) + §2 (map optimization) — both pure client, no backend,
  ship via the existing CLI pipeline (remember the "What's New" + don't-cancel-
  in-review habits).
- **v2.1:** Prague live map + (optionally) §3 MetricKit→proxy, since the proxy
  exists then.
- §3 baseline (Organizer) applies immediately, no release needed.
