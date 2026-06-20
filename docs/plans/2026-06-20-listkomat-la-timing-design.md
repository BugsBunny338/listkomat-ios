# Lístkomat — Live Activity timing buffer (design)

*Date: 2026-06-20 · Status: VALIDATED — ready for a writing-plans pass*

Implements §1 of `2026-06-20-listkomat-hardening-polish-design.md`. From Eva K.'s
real-user feedback on the live 2.0: the ticket Live Activity starts its countdown
the instant the SMS is *sent*, but the ticket is only valid from the operator's
*confirmation SMS* (~2 min later). A fare check in that gap could mean a fine.

## Root constraint (why no backend)
Apple blocks apps from reading the delivered/confirmation SMS, so we can never
*know* when the ticket actually became valid. A backend + APNs push could only
fire at `sent + 120s` — the same estimate we compute on-device — so it buys only
a cosmetic locked-screen label flip, not better timing. Decision (2026-06-20):
ship the on-device design now (2.0.1); a push-based label polish can slot in
later when the Prague caching proxy exists. The design below is forward-compatible
with that addition.

## Chosen UX — two self-ticking timers
`Text(timerInterval:)` updates on-device with no push, so both phases render
correctly on a locked screen with zero server involvement:
- **Buffer (first ~120 s):** show "Aktivuje se — čeká na potvrzovací SMS", a
  `platí za M:SS` countdown to `validFrom`, and the validity time sitting frozen
  at full (`zbývá 30:00`).
- **At `validFrom` (automatic):** the validity timer begins ticking; the buffer
  timer reads `0:00`. No push, no scheduled update.
- **Potvrdit nyní:** in-app banner button — re-anchors `validFrom = now` for users
  whose confirmation SMS arrived early. (iOS 16.2 Live Activities aren't
  interactive; in-activity buttons are a deferred iOS-17+ enhancement — YAGNI.)
- **Ukončit:** unchanged manual cancel (covers a failed send; `.sent` ≠ delivered).

Safety direction is correct: during the buffer it never claims validity, and if
confirmation runs long the countdown under-counts (conservative).

**Explicitly NOT doing now:** the best-effort scheduled local `activity.update`
to drop the pending label — it won't fire on a locked screen, so it adds code for
a case it can't serve. Correctness comes from the self-ticking timers; the clean
label drop waits for the (later, optional) push.

## Data model — `TicketTimeline` (pure, TDD'd)
New value type in `Shared/`, independent of ActivityKit so it's unit-testable:
```
struct TicketTimeline: Codable, Hashable {
    var sentAt: Date
    var validFrom: Date
    var endDate: Date
    var duration: TimeInterval { endDate.timeIntervalSince(validFrom) }
    func isPending(at now: Date) -> Bool { now < validFrom }
    static let buffer: TimeInterval = 120
    static func make(sentAt: Date, durationSeconds: TimeInterval,
                     buffer: TimeInterval = buffer) -> TicketTimeline
    func confirmed(at now: Date) -> TicketTimeline   // re-anchor validFrom=now, keep duration
}
```
- `make`: `validFrom = sentAt + buffer`, `endDate = validFrom + durationSeconds`.
- `confirmed`: `validFrom = now`, `endDate = now + duration` (duration preserved
  via the `endDate − validFrom` invariant — no need to store duration separately).

## Wiring
- **`ContentState`** carries `sentAt`, `validFrom`, `endDate` (replaces today's
  `startDate`/`endDate`). Built from a `TicketTimeline`.
- **`LiveActivityController.start(city:ticket:)`**: `TicketTimeline.make(sentAt: now,
  durationSeconds: ticket.durationMinutes*60)`; request the activity from it.
  Add **`confirmNow()`** → `timeline.confirmed(at: now)` + `activity.update`.
  `stop()` unchanged. `ActiveTicket` gains `validFrom` so the banner knows pending.
- **Widget (`TicketLiveActivity`)**: lock screen + Dynamic Island expanded render
  the two timers + the pending note; compact/minimal keep the single validity
  timer (`validFrom…endDate`) for consistency.
- **In-app banner (`ContentView`)**: while `now < active.validFrom`, show the
  "čeká na potvrzení" copy + a **Potvrdit nyní** button (`liveActivity.confirmNow()`);
  otherwise the normal active row. Keep **Ukončit**.

## Testing
- **Unit (TDD):** `TicketTimeline` — `make` sets validFrom/endDate correctly;
  `isPending` true at `sentAt`, false at/after `validFrom`; `confirmed` re-anchors
  to now and preserves duration; buffer constant applied.
- **Integration:** ActivityKit/widget/banner wiring verified by clean build +
  simulator demo (the sim hook in `TicketListView` already starts an activity so
  the buffer→active transition is observable), same as the map view-layer work.

## Ship
Lands in **2.0.1** alongside the map-performance work. Bump MARKETING_VERSION→2.0.1
+ CURRENT_PROJECT_VERSION, fresh "What's New", `scripts/release.sh`, don't cancel
in review. Deferred for the backend era: APNs push to flip the pending label
cleanly on a locked screen.
