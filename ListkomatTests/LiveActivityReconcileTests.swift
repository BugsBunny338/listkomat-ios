import ActivityKit
import XCTest
@testable import Listkomat

/// Regression cover for issue #19 — "Potvrdit nyní" needed two taps.
///
/// `confirmNow()` writes the confirmed state optimistically and then reconciles
/// against ActivityKit. ActivityKit's `content.state` does NOT reflect an update
/// the moment `await activity.update(...)` returns (measured on device/simulator:
/// the read-back still carried the pre-update `validFrom`), so a reconcile that
/// trusts that snapshot reverts the banner to "čeká na potvrzovací SMS" and the
/// user has to tap again.
@MainActor
final class LiveActivityReconcileTests: XCTestCase {
    private let sentAt = Date(timeIntervalSince1970: 1_800_000_000)

    private func ticket(validFrom: Date) -> LiveActivityController.ActiveTicket {
        LiveActivityController.ActiveTicket(cityName: "Praha", ticketLabel: "30 min",
                                            validFrom: validFrom)
    }

    /// The #19 bug: the snapshot still says "pending" because the update we just
    /// made hasn't propagated. The confirmed local value must survive.
    func testStaleSnapshotDoesNotRevertConfirmedTicket() {
        let confirmed = ticket(validFrom: sentAt)                              // confirmNow(): valid now
        let stalePending = ticket(validFrom: sentAt.addingTimeInterval(120))   // pre-update snapshot

        let result = LiveActivityController.reconciled(local: confirmed, snapshot: stalePending)

        XCTAssertEqual(result, confirmed,
                       "a not-yet-propagated snapshot must not push the banner back to pending")
    }

    /// The reconcile still has to do its real job: if the activity was ended or
    /// dismissed out from under us, the banner goes away.
    func testEndedActivityClearsTheBanner() {
        let confirmed = ticket(validFrom: sentAt)

        XCTAssertNil(LiveActivityController.reconciled(local: confirmed, snapshot: nil))
    }

    /// Fresh launch with an activity already running: nothing local to trust, so
    /// ActivityKit's snapshot is adopted.
    func testAdoptsSnapshotWhenThereIsNoLocalState() {
        let running = ticket(validFrom: sentAt.addingTimeInterval(120))

        XCTAssertEqual(LiveActivityController.reconciled(local: nil, snapshot: running), running)
    }

    func testNoActivityAndNoLocalStateStaysEmpty() {
        XCTAssertNil(LiveActivityController.reconciled(local: nil, snapshot: nil))
    }

    // MARK: - Which activities the banner represents

    /// `Activity.activities` keeps an activity after it ends until it is dismissed
    /// (verified on the simulator), so those must not count as a live ticket.
    func testEndedAndDismissedActivitiesAreNotLive() {
        XCTAssertFalse(LiveActivityController.isLive(.ended))
        XCTAssertFalse(LiveActivityController.isLive(.dismissed))
    }

    /// ⚠️ Guards a trap: this app repurposes `staleDate` as a phase flag and
    /// `confirmNow()` sets it to now, so a *confirmed* ticket's activity is `.stale`.
    /// Narrowing this predicate to `== .active` would blank the banner on every
    /// confirmation.
    func testStaleActivityIsStillLive() {
        XCTAssertTrue(LiveActivityController.isLive(.active))
        XCTAssertTrue(LiveActivityController.isLive(.stale))
    }

    // MARK: - Banner pending boundary

    /// The banner must compare against the wall clock, not only the TimelineView
    /// schedule entry, which can lag by up to a tick.
    func testIsPendingBoundary() {
        let t = ticket(validFrom: sentAt)
        XCTAssertTrue(t.isPending(at: sentAt.addingTimeInterval(-0.5)))
        XCTAssertFalse(t.isPending(at: sentAt))                          // valid exactly at validFrom
        XCTAssertFalse(t.isPending(at: sentAt.addingTimeInterval(0.5)))
    }
}
