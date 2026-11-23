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
        ActiveTicket(cityKey: cityKey, cityName: "Praha", ticketCode: "DPT31",
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

    // MARK: - Title at render time (P1 2d)

    /// The compiled table of one language, so a test can pin it.
    private func lproj(_ language: String) throws -> Bundle {
        let app = Bundle(for: CatalogStore.self)
        let path = try XCTUnwrap(app.path(forResource: language, ofType: "lproj"), "\(language).lproj")
        return try XCTUnwrap(Bundle(path: path))
    }

    func testTitleIsBuiltInTheCurrentLanguage() throws {
        let cs = try lproj("cs"), en = try lproj("en")
        let csLocale = Locale(identifier: "cs_CZ"), enLocale = Locale(identifier: "en_US")
        XCTAssertEqual(ticket().title(cityName: "Praha", bundle: cs, locale: csLocale), "Praha · 30 minut")
        XCTAssertEqual(ticket().title(cityName: "Prague", bundle: en, locale: enLocale), "Prague · 30 minutes")
        func title(_ minutes: Int, _ bundle: Bundle, _ locale: Locale) -> String {
            var t = ticket()
            t.timeline = TicketTimeline.make(sentAt: t0, durationSeconds: Double(minutes) * 60)
            return t.title(cityName: "X", bundle: bundle, locale: locale)
        }
        XCTAssertEqual(title(1, cs, csLocale), "X · 1 minutu")
        XCTAssertEqual(title(1, en, enLocale), "X · 1 minute")
        XCTAssertEqual(title(60, cs, csLocale), "X · 60 minut")
        XCTAssertEqual(title(120, cs, csLocale), "X · 2 hodiny")
        XCTAssertEqual(title(120, en, enLocale), "X · 2 hours")
        XCTAssertEqual(title(1440, cs, csLocale), "X · 24 hodin")
        XCTAssertEqual(title(1440, en, enLocale), "X · 24 hours")
    }

    /// No Czech fragment in an English title, whatever language the ticket was
    /// bought in: nothing about the duration is stored as words any more.
    func testEnglishTitleHasNoCzechFragment() throws {
        let title = ticket().title(cityName: "Prague", bundle: try lproj("en"), locale: Locale(identifier: "en_US"))
        XCTAssertFalse(title.contains("minut "))
        XCTAssertFalse(title.hasSuffix("minut"))
    }

    /// "Potvrdit nyní" re-anchors the window but keeps its length, so the
    /// title's duration doesn't drift.
    func testDurationSurvivesConfirmNow() {
        var t = ticket()
        XCTAssertEqual(t.durationMinutes, 30)
        t.timeline = t.timeline.confirmed(at: t0.addingTimeInterval(37))
        XCTAssertEqual(t.durationMinutes, 30)
    }

    /// A ticket persisted by 2.6 carries a `ticketLabel` localized at purchase.
    /// It must still decode (the key is ignored) after the upgrade.
    func testTicketStoredBy26StillDecodes() throws {
        // JSONEncoder's default dates: seconds since 2001-01-01.
        let sent = t0.timeIntervalSinceReferenceDate
        let json = """
        {"cityKey":"praha","cityName":"Praha","ticketLabel":"30 minut","ticketCode":"DPT31",\
        "priceKc":42,"accentHex":5686479,\
        "timeline":{"sentAt":\(sent),"validFrom":\(sent + 120),"endDate":\(sent + 1920)}}
        """
        defaults.set(Data(json.utf8), forKey: ActiveTicketStore.key)
        let loaded = try XCTUnwrap(ActiveTicketStore(defaults: defaults).load())
        XCTAssertEqual(loaded, ticket())
        XCTAssertEqual(loaded.durationMinutes, 30)
        XCTAssertEqual(loaded.title(cityName: "Prague", bundle: try lproj("en"), locale: Locale(identifier: "en_US")),
                       "Prague · 30 minutes")
    }

    /// The 2.6 shape of a ticket adopted from a 2.5 Live Activity (no key, no code).
    func testAdoptedTicketStoredBy26StillDecodes() throws {
        let sent = t0.timeIntervalSinceReferenceDate
        let json = """
        {"cityName":"Brno","ticketLabel":"90 minut","priceKc":30,\
        "timeline":{"sentAt":\(sent),"validFrom":\(sent + 120),"endDate":\(sent + 5520)}}
        """
        defaults.set(Data(json.utf8), forKey: ActiveTicketStore.key)
        let loaded = try XCTUnwrap(ActiveTicketStore(defaults: defaults).load())
        XCTAssertNil(loaded.cityKey)
        XCTAssertNil(loaded.ticketCode)
        XCTAssertEqual(loaded.durationMinutes, 90)
    }

    func testNewTicketsStoreNoLabel() throws {
        let data = try JSONEncoder().encode(ticket())
        let keys = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]).keys
        XCTAssertFalse(keys.contains("ticketLabel"))
    }

    /// The Live Activity words the duration itself (same language as its
    /// sentence); an activity started by 2.6 falls back to its stored label.
    func testActivityAttributesDurationLabel() throws {
        let old = TicketActivityAttributes(cityName: "Praha", ticketLabel: "30 minut", priceKc: 42, accentHex: nil)
        XCTAssertEqual(old.durationLabel, "30 minut")
        let new = TicketActivityAttributes(cityName: "Praha", ticketLabel: "30 minut", priceKc: 42,
                                           accentHex: nil, durationMinutes: 30)
        XCTAssertEqual(new.durationLabel, TicketDuration.label(minutes: 30))
        // A 2.6 activity's attributes (no durationMinutes) decode.
        let json = #"{"cityName":"Praha","ticketLabel":"30 minut","priceKc":42}"#
        let decoded = try JSONDecoder().decode(TicketActivityAttributes.self, from: Data(json.utf8))
        XCTAssertNil(decoded.durationMinutes)
        XCTAssertEqual(decoded.durationLabel, "30 minut")
    }
}
