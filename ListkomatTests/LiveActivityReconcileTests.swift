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
}
