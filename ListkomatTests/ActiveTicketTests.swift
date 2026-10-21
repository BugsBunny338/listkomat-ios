import ActivityKit
import XCTest
@testable import Listkomat

/// G3: the stored ticket is the source of truth outside ActivityKit.
final class ActiveTicketTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private var defaults: UserDefaults!
    private let suite = "ActiveTicketTests"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func ticket(cityKey: String? = "praha") -> ActiveTicket {
        ActiveTicket(cityKey: cityKey, cityName: "Praha", ticketLabel: "30 minut", ticketCode: "DPT31",
                     priceKc: 42, accentHex: 0x56C4CF,
                     timeline: TicketTimeline.make(sentAt: t0, durationSeconds: 1800))
    }

    // MARK: - Store

    func testStoreRoundTrip() {
        let store = ActiveTicketStore(defaults: defaults)
        XCTAssertNil(store.load())
        store.save(ticket())
        XCTAssertEqual(store.load(), ticket())
        // A second store over the same defaults = a relaunch.
        XCTAssertEqual(ActiveTicketStore(defaults: defaults).load(), ticket())
        store.clear()
        XCTAssertNil(store.load())
    }

    /// A ticket adopted from a 2.5 Live Activity has no key or code.
    func testStoreRoundTripWithoutKeyOrCode() {
        let store = ActiveTicketStore(defaults: defaults)
        var adopted = ticket(cityKey: nil)
        adopted.ticketCode = nil
        adopted.accentHex = nil
        store.save(adopted)
        XCTAssertEqual(store.load(), adopted)
    }

    func testCorruptStoreReadsAsNoTicket() {
        defaults.set(Data("not json".utf8), forKey: ActiveTicketStore.key)
        XCTAssertNil(ActiveTicketStore(defaults: defaults).load())
    }

    // MARK: - Relaunch

    func testRestoredKeepsRunningAndFreshlyExpiredTickets() {
        let t = ticket()
        XCTAssertEqual(ActiveTicket.restored(t, now: t0), t)                                      // pending
        XCTAssertEqual(ActiveTicket.restored(t, now: t.timeline.endDate.addingTimeInterval(-1)), t) // valid
        XCTAssertEqual(ActiveTicket.restored(t, now: t.timeline.endDate), t)                      // just expired
        XCTAssertEqual(ActiveTicket.restored(t, now: t.timeline.endDate.addingTimeInterval(3599)), t)
    }

    /// Android drops a ticket that expired more than an hour ago at launch.
    func testRestoredDropsTicketsExpiredOverAnHourAgo() {
        let t = ticket()
        XCTAssertNil(ActiveTicket.restored(t, now: t.timeline.endDate.addingTimeInterval(3600)))
        XCTAssertNil(ActiveTicket.restored(nil, now: t0))
    }

    // MARK: - Phases (banner)

    func testPhaseBoundaries() {
        let tl = ticket().timeline
        XCTAssertEqual(tl.phase(at: t0), .pending)
        XCTAssertEqual(tl.phase(at: tl.validFrom.addingTimeInterval(-0.5)), .pending)
        XCTAssertEqual(tl.phase(at: tl.validFrom), .valid)                 // valid exactly at validFrom
        XCTAssertEqual(tl.phase(at: tl.endDate.addingTimeInterval(-0.5)), .valid)
        XCTAssertEqual(tl.phase(at: tl.endDate), .expired)                 // expired exactly at endDate
        let confirmed = tl.confirmed(at: t0.addingTimeInterval(30))
        XCTAssertEqual(confirmed.phase(at: t0.addingTimeInterval(30)), .valid)
    }

    // MARK: - Live Activity mirror

    /// `Activity.activities` keeps an activity after it ends until it is dismissed
    /// (verified on the simulator), so those must not count as running.
    func testEndedAndDismissedActivitiesAreNotLive() {
        XCTAssertFalse(LiveActivityController.isLive(.ended))
        XCTAssertFalse(LiveActivityController.isLive(.dismissed))
    }

    /// ⚠️ Guards a trap: this app repurposes `staleDate` as a phase flag and
    /// `confirmNow()` sets it to now, so a *confirmed* ticket's activity is `.stale`.
    /// Narrowing this predicate to `== .active` would stop it being updated or ended.
    func testStaleActivityIsStillLive() {
        XCTAssertTrue(LiveActivityController.isLive(.active))
        XCTAssertTrue(LiveActivityController.isLive(.stale))
    }

    /// Content from a running 2.5 activity (no `expired` key) decodes as not
    /// expired, and the flag survives a round trip.
    func testContentStateExpiredFlagDecoding() throws {
        let legacy = #"{"sentAt":0,"validFrom":120,"endDate":1920}"#
        let decoded = try JSONDecoder().decode(TicketActivityAttributes.ContentState.self, from: Data(legacy.utf8))
        XCTAssertFalse(decoded.expired)

        var state = decoded
        state.expired = true
        let back = try JSONDecoder().decode(TicketActivityAttributes.ContentState.self,
                                            from: JSONEncoder().encode(state))
        XCTAssertTrue(back.expired)
        XCTAssertEqual(back.endDate, decoded.endDate)
    }
}
