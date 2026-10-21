import XCTest
@testable import Listkomat

/// G5: mirrors Android's CitySelectionTest (keys × grace × permission × hold),
/// so both apps pick the same city in the same situation.
final class CitySelectionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let inPrague = LocationState.located(cityKey: "praha", distanceKm: 2)
    private let inSaltLakeCity = LocationState.located(cityKey: "brno", distanceKm: 9_200)

    // MARK: - Which city is shown

    func testGPSWinsOverThePersistedFallback() {
        XCTAssertEqual(CitySelection.cityKey(manual: nil, location: inPrague, fallback: "brno"), "praha")
    }

    func testManualPickThisSessionWinsOverGPS() {
        XCTAssertEqual(CitySelection.cityKey(manual: "brno", location: inPrague, fallback: "brno"), "brno")
    }

    func testTooFarFromEveryCityFallsBackToTheLastPick() {
        XCTAssertEqual(CitySelection.cityKey(manual: nil, location: inSaltLakeCity, fallback: "brno"), "brno")
    }

    func testTooFarWithNoFallbackShowsNothing() {
        XCTAssertNil(CitySelection.cityKey(manual: nil, location: inSaltLakeCity, fallback: nil))
    }

    func testDeniedIdleOrSearchingFallBackToTheLastPick() {
        for state in [LocationState.denied, .idle, .searching] {
            XCTAssertEqual(CitySelection.cityKey(manual: nil, location: state, fallback: "ostrava"), "ostrava",
                           "\(state)")
        }
    }

    func testDeniedIdleOrSearchingWithNoFallbackShowNothing() {
        for state in [LocationState.denied, .idle, .searching] {
            XCTAssertNil(CitySelection.cityKey(manual: nil, location: state, fallback: nil), "\(state)")
        }
    }

    func testTheHundredKilometreLimitItselfStillCountsAsNearby() {
        XCTAssertEqual(CitySelection.gpsCityKey(.located(cityKey: "brno", distanceKm: 100)), "brno")
        XCTAssertNil(CitySelection.gpsCityKey(.located(cityKey: "brno", distanceKm: 100.1)))
    }

    // MARK: - The short hold for a first fix, so the list doesn't swap in place

    func testWhileTheFirstFixIsAwaitedTheFallbackIsHeldBack() {
        XCTAssertNil(CitySelection.cityKey(manual: nil, location: .searching, fallback: "brno",
                                           awaitingFirstFix: true))
    }

    func testOnceTheHoldIsOverTheFallbackShows() {
        XCTAssertEqual(CitySelection.cityKey(manual: nil, location: .searching, fallback: "brno",
                                             awaitingFirstFix: false), "brno")
    }

    func testAManualPickIsNeverHeldBack() {
        XCTAssertEqual(CitySelection.cityKey(manual: "brno", location: .searching, fallback: "brno",
                                             awaitingFirstFix: true), "brno")
    }

    func testAFixThatArrivesDuringTheHoldShowsStraightAway() {
        XCTAssertEqual(CitySelection.cityKey(manual: nil, location: inPrague, fallback: "brno",
                                             awaitingFirstFix: true), "praha")
    }

    func testATooFarFixDuringTheHoldStillHoldsTheFallbackBack() {
        // ContentView ends the hold on any answer; this only covers the gap.
        XCTAssertNil(CitySelection.cityKey(manual: nil, location: inSaltLakeCity, fallback: "brno",
                                           awaitingFirstFix: true))
    }

    // MARK: - A cached fix counts only when recent

    func testFixAgeLimits() {
        XCTAssertTrue(CitySelection.fixIsFresh(age: 6 * 60))
        XCTAssertTrue(CitySelection.fixIsFresh(age: CitySelection.fixMaxAge))
        XCTAssertFalse(CitySelection.fixIsFresh(age: CitySelection.fixMaxAge + 1))
        XCTAssertFalse(CitySelection.fixIsFresh(age: -1), "a fix from the future (clock skew) is not fresh")
    }

    // MARK: - Does the manual pick survive a return to the app

    func testAPickMadeMomentsAgoSurvivesAReturn() {
        XCTAssertEqual(CitySelection.overrideAfterStart(fallback: "brno", lastSeenAt: now - 10, now: now), "brno")
    }

    func testAPickJustInsideTheGraceWindowSurvives() {
        let lastSeen = now - CitySelection.manualGrace + 0.001
        XCTAssertEqual(CitySelection.overrideAfterStart(fallback: "brno", lastSeenAt: lastSeen, now: now), "brno")
    }

    func testAPickOlderThanTheGraceWindowNoLongerOverridesGPS() {
        let lastSeen = now - CitySelection.manualGrace
        XCTAssertNil(CitySelection.overrideAfterStart(fallback: "brno", lastSeenAt: lastSeen, now: now))
    }

    func testAPickWithNoTimestampNeverOverridesGPS() {
        XCTAssertNil(CitySelection.overrideAfterStart(fallback: "brno", lastSeenAt: nil, now: now))
    }

    func testAPickInTheFutureDoesNotOverrideGPS() {
        XCTAssertNil(CitySelection.overrideAfterStart(fallback: "brno", lastSeenAt: now + 60, now: now))
    }

    func testNoPickAtAllMeansNoOverride() {
        XCTAssertNil(CitySelection.overrideAfterStart(fallback: nil, lastSeenAt: nil, now: now))
    }

    // MARK: - Walkthroughs, end to end

    func testPickBrnoAbroadComeBackAfterTheGraceWindowStillBrno() {
        let manual = CitySelection.overrideAfterStart(fallback: "brno", lastSeenAt: now - 3600, now: now)
        XCTAssertEqual(CitySelection.cityKey(manual: manual, location: inSaltLakeCity, fallback: "brno"), "brno")
    }

    func testPickBrnoComeBackInPragueAfterTheGraceWindowPragueWins() {
        let manual = CitySelection.overrideAfterStart(fallback: "brno", lastSeenAt: now - 3600, now: now)
        XCTAssertEqual(CitySelection.cityKey(manual: manual, location: inPrague, fallback: "brno"), "praha")
    }

    func testPickBrnoInPragueAnswerATextAndComeBackStillBrno() {
        let manual = CitySelection.overrideAfterStart(fallback: "brno", lastSeenAt: now - 60, now: now)
        XCTAssertEqual(CitySelection.cityKey(manual: manual, location: inPrague, fallback: "brno"), "brno")
    }

    /// The grace counts from leaving the app (ContentView stamps it on
    /// `.background`), not from the pick ten minutes earlier.
    func testPickBrnoBrowseTenMinutesLeaveAndComeBackStillBrno() {
        let left = now - 40
        let manual = CitySelection.overrideAfterStart(fallback: "brno", lastSeenAt: left, now: now)
        XCTAssertEqual(CitySelection.cityKey(manual: manual, location: inPrague, fallback: "brno"), "brno")
    }

    func testPickBrnoRevokeLocationBrnoWithoutAnEmptyState() {
        let manual = CitySelection.overrideAfterStart(fallback: "brno", lastSeenAt: now - 3600, now: now)
        XCTAssertEqual(CitySelection.cityKey(manual: manual, location: .denied, fallback: "brno"), "brno")
    }
}
