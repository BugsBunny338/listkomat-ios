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

    func testConfirmedAfterValidityStartedStillReanchorsFromNow() {
        // User taps "Potvrdit nyní" after the buffer already elapsed: re-anchor to
        // now and give the full duration again (generous but intended — the real
        // validity only just began at confirmation).
        let tl = TicketTimeline.make(sentAt: t0, durationSeconds: 1800)
        let at = t0.addingTimeInterval(200)                             // past validFrom (120)
        let c = tl.confirmed(at: at)
        XCTAssertEqual(c.validFrom, at)
        XCTAssertEqual(c.endDate, at.addingTimeInterval(1800))
        XCTAssertEqual(c.duration, 1800, accuracy: 0.001)
    }

    func testCustomBufferParameter() {
        // The sim demo lowers the buffer to watch the auto-flip — lock that knob.
        let tl = TicketTimeline.make(sentAt: t0, durationSeconds: 1800, buffer: 10)
        XCTAssertEqual(tl.validFrom, t0.addingTimeInterval(10))
        XCTAssertEqual(tl.endDate, t0.addingTimeInterval(10 + 1800))
    }

    func testLegacyContentStateDecodes() throws {
        // A 2.0 activity persisted {startDate, endDate}; it must still decode after
        // the field migration (startDate → sentAt + validFrom), not throw.
        let legacy = #"{"startDate": 700000000, "endDate": 700001800}"#
        let state = try JSONDecoder().decode(
            TicketActivityAttributes.ContentState.self, from: Data(legacy.utf8))
        let start = Date(timeIntervalSinceReferenceDate: 700000000)
        XCTAssertEqual(state.sentAt, start)
        XCTAssertEqual(state.validFrom, start)                          // no buffer for legacy
        XCTAssertEqual(state.endDate, Date(timeIntervalSinceReferenceDate: 700001800))
    }

    func testContentStateRoundTrips() throws {
        let original = TicketActivityAttributes.ContentState(
            sentAt: t0, validFrom: t0.addingTimeInterval(120), endDate: t0.addingTimeInterval(1920))
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TicketActivityAttributes.ContentState.self, from: data)
        XCTAssertEqual(decoded, original)
    }
}
