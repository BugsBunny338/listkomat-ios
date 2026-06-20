# Live Activity Timing Buffer — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Stop the ticket Live Activity from claiming validity during the ~2-min gap between SMS send and the operator's confirmation, by anchoring the countdown to `validFrom = sent + 120s` and showing a clear pending state — all on-device, no backend.

**Architecture:** A pure `TicketTimeline` value type (in `Shared/`, ActivityKit-free) does all the date math and is fully unit-tested. The Live Activity's `ContentState` carries `sentAt`/`validFrom`/`endDate`; the widget renders two self-ticking `Text(timerInterval:)` views ("platí za" buffer countdown + "zbývá" validity countdown) so the pending→valid transition happens automatically with no push. An in-app "Potvrdit nyní" button re-anchors `validFrom = now`. Forward-compatible with a later APNs push for cosmetic label cleanup.

**Tech Stack:** Swift 6 / SwiftUI, ActivityKit + WidgetKit, XCTest, XcodeGen. Design: `docs/plans/2026-06-20-listkomat-la-timing-design.md`.

**Working context:** In place on `main` (no worktree). Sources are folder-globbed in `project.yml` (`Shared` → app + widget; `ListkomatTests` → test target), so **after adding any new file run `xcodegen generate`** before building (the `.xcodeproj` is generated/gitignored).

**Test/build command (note the explicit `-project`, cwd resets to `~/prj`):**
```bash
xcodebuild test -project /Users/bugsbunny/prj/listkomat/Listkomat.xcodeproj \
  -scheme Listkomat -destination 'platform=iOS Simulator,name=iPhone 17' \
  -sdk iphonesimulator -derivedDataPath /tmp/lk-dd 2>&1 | tail -40
```
Single class: append `-only-testing:ListkomatTests/TicketTimelineTests`.

---

## Task 1: `TicketTimeline` pure value type (TDD)

All the logic that can be wrong lives here; ActivityKit/widget are dumb renderers.

**Files:**
- Create: `Shared/TicketTimeline.swift`
- Create: `ListkomatTests/TicketTimelineTests.swift`

**Step 1: Write the failing tests**

`ListkomatTests/TicketTimelineTests.swift`:
```swift
import XCTest
@testable import Listkomat

final class TicketTimelineTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testMakeAppliesBufferAndDuration() {
        let tl = TicketTimeline.make(sentAt: t0, durationSeconds: 1800)  // 30 min
        XCTAssertEqual(tl.validFrom, t0.addingTimeInterval(120))         // default 120s buffer
        XCTAssertEqual(tl.endDate, t0.addingTimeInterval(120 + 1800))
        XCTAssertEqual(tl.duration, 1800, accuracy: 0.001)
    }

    func testIsPendingBoundary() {
        let tl = TicketTimeline.make(sentAt: t0, durationSeconds: 1800)
        XCTAssertTrue(tl.isPending(at: t0))
        XCTAssertTrue(tl.isPending(at: t0.addingTimeInterval(119)))
        XCTAssertFalse(tl.isPending(at: t0.addingTimeInterval(120)))     // valid exactly at validFrom
        XCTAssertFalse(tl.isPending(at: t0.addingTimeInterval(300)))
    }

    func testConfirmedReanchorsAndPreservesDuration() {
        let tl = TicketTimeline.make(sentAt: t0, durationSeconds: 1800)
        let at = t0.addingTimeInterval(45)
        let c = tl.confirmed(at: at)
        XCTAssertEqual(c.validFrom, at)
        XCTAssertEqual(c.endDate, at.addingTimeInterval(1800))           // full 30 min from now
        XCTAssertEqual(c.duration, 1800, accuracy: 0.001)
        XCTAssertFalse(c.isPending(at: at))
        XCTAssertEqual(c.sentAt, t0)                                     // sentAt unchanged
    }
}
```

**Step 2: Run to verify it fails**

Run the single-class command. Expected: FAIL to compile (`TicketTimeline` undefined). Acceptable red.

**Step 3: Write minimal implementation**

`Shared/TicketTimeline.swift`:
```swift
import Foundation

/// All ticket-validity date math, ActivityKit-free so it's unit-testable.
/// The ticket isn't valid until the operator's confirmation SMS (~2 min after
/// send, unreadable by apps), so validity is anchored to `validFrom`, not send.
struct TicketTimeline: Codable, Hashable {
    var sentAt: Date
    var validFrom: Date
    var endDate: Date

    /// Length of the valid window (invariant: endDate − validFrom).
    var duration: TimeInterval { endDate.timeIntervalSince(validFrom) }

    /// Before this, the ticket shows as "čeká na potvrzení", not counting down.
    func isPending(at now: Date) -> Bool { now < validFrom }

    /// Estimated gap between SMS send and the confirmation SMS.
    static let buffer: TimeInterval = 120

    static func make(sentAt: Date,
                     durationSeconds: TimeInterval,
                     buffer: TimeInterval = buffer) -> TicketTimeline {
        let validFrom = sentAt.addingTimeInterval(buffer)
        return TicketTimeline(sentAt: sentAt,
                              validFrom: validFrom,
                              endDate: validFrom.addingTimeInterval(durationSeconds))
    }

    /// Re-anchor to now (confirmation arrived), keeping the same duration.
    func confirmed(at now: Date) -> TicketTimeline {
        TicketTimeline(sentAt: sentAt, validFrom: now, endDate: now.addingTimeInterval(duration))
    }
}
```

**Step 4: Run to verify it passes**

```bash
xcodegen generate   # pick up the two new files
```
Then the single-class command. Expected: PASS (3 tests). Re-run the full suite — still green.

**Step 5: Commit**
```bash
git add Shared/TicketTimeline.swift ListkomatTests/TicketTimelineTests.swift
git commit -m "feat(la): TicketTimeline — validity anchored to validFrom (buffer + re-anchor)"
```

---

## Task 2: Migrate `ContentState` + controller onto `TicketTimeline`

Refactor: change the state shape and its one producer + one consumer together so the project keeps compiling. No new unit test (math is covered by Task 1); the gate is a green build + existing tests.

**Files:**
- Modify: `Shared/TicketActivityAttributes.swift`
- Modify: `Listkomat/Services/LiveActivityController.swift` (`start`)
- Modify: `ListkomatWidgets/TicketLiveActivity.swift` (minimal — just compile against new fields; full UI is Task 3)

**Step 1: Update `ContentState`**

In `TicketActivityAttributes.swift`, replace the `ContentState`:
```swift
struct ContentState: Codable, Hashable {
    var sentAt: Date
    var validFrom: Date
    var endDate: Date
}
```

**Step 2: Build `start()` from a `TicketTimeline`**

In `LiveActivityController.start(city:ticket:)`, replace the `start`/`end` date construction:
```swift
let timeline = TicketTimeline.make(sentAt: Date(),
                                   durationSeconds: Double(ticket.durationMinutes) * 60)
let attributes = TicketActivityAttributes(
    cityName: city.name, ticketLabel: ticket.duration, priceKc: ticket.priceKc)
let state = TicketActivityAttributes.ContentState(
    sentAt: timeline.sentAt, validFrom: timeline.validFrom, endDate: timeline.endDate)
_ = try Activity.request(attributes: attributes,
                         content: ActivityContent(state: state, staleDate: timeline.endDate))
active = ActiveTicket(cityName: city.name, ticketLabel: ticket.duration)
```

**Step 3: Keep the widget compiling**

In `TicketLiveActivity.swift`, replace every `context.state.startDate...context.state.endDate` with `context.state.validFrom...context.state.endDate` (4 occurrences: DI expanded trailing, DI compactTrailing, lock-screen). Leave layout otherwise unchanged for now.

**Step 4: Build to verify it compiles + nothing regressed**

```bash
xcodegen generate
```
Then the full test command. Expected: BUILD SUCCEEDED, all tests PASS (Task 1 + map + catalog, no behaviour touched by tests).

**Step 5: Commit**
```bash
git add Shared/TicketActivityAttributes.swift Listkomat/Services/LiveActivityController.swift ListkomatWidgets/TicketLiveActivity.swift
git commit -m "refactor(la): ContentState carries sentAt/validFrom/endDate via TicketTimeline"
```

---

## Task 3: Widget dual-timer + pending note

View-layer; verified by build + sim demo (Task 6), no unit test. Render both self-ticking timers so the buffer→valid transition is automatic with no push.

**Files:**
- Modify: `ListkomatWidgets/TicketLiveActivity.swift`

**Step 1: Lock-screen view — add the buffer row**

In `LockScreenView`, under the city/price `VStack`, add a pending line and a second timer. The buffer timer counts `sentAt…validFrom`; the validity timer stays `validFrom…endDate`:
```swift
// inside the leading VStack, after the price line:
Text("čeká na potvrzovací SMS")
    .font(.caption2)
    .foregroundStyle(.orange)
```
And in the trailing `VStack`, above "zbývá"/the validity timer, add:
```swift
Text("platí za ")
    + Text(timerInterval: context.state.sentAt...context.state.validFrom, countsDown: true)
```
(rendered small/secondary). The existing `zbývá` + `validFrom…endDate` timer stays as the primary number. Keep it readable: buffer line `.font(.caption2).foregroundStyle(.secondary)`.

> Note: `Text(timerInterval:)` self-ticks; during the buffer the validity timer
> sits frozen at full and the "platí za" timer counts to 0:00, then the validity
> timer begins — no state update needed. After validity starts, the pending line
> and "platí za 0:00" simply linger (acceptable; cleanup waits for the later push).

**Step 2: Dynamic Island expanded — mirror it**

In the `.bottom` expanded region, append the pending note + buffer timer below the existing "Lístek na …" line, same as the lock screen.

**Step 3: Build**

```bash
xcodegen generate
```
Full test command. Expected: BUILD SUCCEEDED, tests green.

**Step 4: Commit**
```bash
git add ListkomatWidgets/TicketLiveActivity.swift
git commit -m "feat(la): widget shows buffer countdown + pending note (self-ticking)"
```

---

## Task 4: `confirmNow()` + `ActiveTicket.validFrom`

**Files:**
- Modify: `Listkomat/Services/LiveActivityController.swift`

**Step 1: Carry `validFrom` on `ActiveTicket`**

```swift
struct ActiveTicket: Equatable {
    let cityName: String
    let ticketLabel: String
    let validFrom: Date
}
```
Set it in `start()` (`validFrom: timeline.validFrom`) and in `syncState()` (read from `activity.content.state.validFrom`; for the no-activity branch set `nil`). Update `syncState()`'s existing `ActiveTicket(...)` constructions accordingly.

**Step 2: Add `confirmNow()`**

```swift
/// User got the confirmation SMS early — re-anchor validity to now.
func confirmNow() {
    guard let activity = Activity<TicketActivityAttributes>.activities.first else { return }
    let s = activity.content.state
    let timeline = TicketTimeline(sentAt: s.sentAt, validFrom: s.validFrom, endDate: s.endDate)
        .confirmed(at: Date())
    let new = TicketActivityAttributes.ContentState(
        sentAt: timeline.sentAt, validFrom: timeline.validFrom, endDate: timeline.endDate)
    Task {
        await activity.update(ActivityContent(state: new, staleDate: timeline.endDate))
        syncState()
    }
}
```

**Step 3: Build**

Full test command (after `xcodegen generate` if needed — no new files here, so regeneration optional). Expected: BUILD SUCCEEDED, tests green.

**Step 4: Commit**
```bash
git add Listkomat/Services/LiveActivityController.swift
git commit -m "feat(la): confirmNow() re-anchors validity; ActiveTicket carries validFrom"
```

---

## Task 5: In-app banner pending state + "Potvrdit nyní"

**Files:**
- Modify: `Listkomat/Views/ContentView.swift` (`activeTicketBanner`)

**Step 1: Show pending copy + confirm button while pending**

Wrap the banner contents in a `TimelineView(.periodic(from: .now, by: 1))` so the in-app banner flips at `validFrom` on its own while the app is open, and branch on pending:
```swift
private func activeTicketBanner(_ active: LiveActivityController.ActiveTicket) -> some View {
    TimelineView(.periodic(from: .now, by: 1)) { ctx in
        let pending = ctx.date < active.validFrom
        HStack(spacing: 12) {
            Image(systemName: "tram.fill").foregroundStyle(theme.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text(pending ? "Čeká na potvrzovací SMS" : "Aktivní lístek")
                    .font(.caption2).foregroundStyle(pending ? .orange : .secondary)
                Text("\(active.cityName) · \(active.ticketLabel)")
                    .font(.brandBold(15, relativeTo: .subheadline))
            }
            Spacer()
            if pending {
                Button("Potvrdit nyní") { liveActivity.confirmNow() }
                    .font(.subheadline.weight(.semibold)).buttonStyle(.bordered).tint(theme.accent)
            }
            Button("Ukončit") { liveActivity.stop() }
                .font(.subheadline.weight(.semibold)).buttonStyle(.bordered).tint(.red)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(theme.accent.opacity(0.12))
    }
}
```

**Step 2: Build**

Full test command. Expected: BUILD SUCCEEDED, tests green.

**Step 3: Commit**
```bash
git add Listkomat/Views/ContentView.swift
git commit -m "feat(la): in-app banner shows pending state + Potvrdit nyní"
```

---

## Task 6: Verify on the simulator (build + demo)

Not a commit — a verification step. The sim hook in `TicketListView` (`#if targetEnvironment(simulator)`) starts an activity on any ticket tap, so the flow is observable without sending SMS.

**Step 1:** `xcodegen generate` then build+install+launch on the booted sim (`xcrun simctl install/launch`, bundle `cz.flipcom.listkomatapp`).

**Step 2:** Tap a ticket → confirm the in-app banner shows **"Čeká na potvrzovací SMS"** + **Potvrdit nyní** + **Ukončit**. (The Live Activity itself doesn't render in the sim's home screen, but the banner exercises the same `ContentState`/`confirmNow` path.)

**Step 3:** Tap **Potvrdit nyní** → banner flips to "Aktivní lístek" (pending=false). Tap **Ukončit** → banner clears. Optionally lower `TicketTimeline.buffer` to ~10s temporarily to watch the automatic flip, then restore 120s.

**Step 4:** If anything's off, fix forward with a follow-up task (don't rewrite history).

---

## Sequencing & ship
Tasks 1→5 in order, commit each; Task 6 verifies. Lands in **2.0.1** with the map-performance work: bump MARKETING_VERSION→2.0.1 + CURRENT_PROJECT_VERSION, **write fresh "What's New"** (project habit — don't carry over), `scripts/release.sh`, don't cancel in review. Deferred to the backend era: an APNs push at `validFrom` to drop the pending label cleanly on a locked screen.
