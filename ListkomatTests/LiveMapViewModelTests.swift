import XCTest
@testable import Listkomat

/// Records lifecycle calls so tests can assert how the view model and the
/// shared-source registry treat a live source (#12: eager connect + warm socket).
private actor SpyVehicleSource: VehicleSource {
    private(set) var fetchCount = 0
    private(set) var shutdownCount = 0
    func fetch() async throws -> [Vehicle] { fetchCount += 1; return [] }
    func shutdown() { shutdownCount += 1 }
}

@MainActor
final class LiveMapViewModelTests: XCTestCase {

    override func setUp() {
        super.setUp()
        LiveSources.reset()
    }

    // MARK: Shared sources (socket survives map close/reopen)

    func testLiveSourcesReturnsSameInstancePerCityKey() {
        let a = LiveSources.source(for: "brno")
        let b = LiveSources.source(for: "brno")
        XCTAssertTrue(a === b, "reopening the map must reuse the existing source (warm socket)")
    }

    func testLiveSourcesKeepsCitiesSeparate() {
        XCTAssertFalse(LiveSources.source(for: "praha") === LiveSources.source(for: "brno"))
    }

    func testMakeForCityUsesSharedSource() {
        let city = City(key: "brno", name: "Brno", lat: 49.19506, lng: 16.606837,
                        smsNumber: "90206", tickets: [])
        let vm1 = LiveMapViewModel.make(for: city)
        let vm2 = LiveMapViewModel.make(for: city)
        XCTAssertTrue(vm1.source === vm2.source,
                      "a new map view must not create a fresh (cold) source")
    }

    // MARK: Warm-up (eager connect from the city screen)

    func testWarmUpFetchesTheCitysSource() async {
        let spy = SpyVehicleSource()
        LiveSources.inject(spy, for: "brno")
        await LiveSources.warmUp(cityKey: "brno")
        let fetched = await spy.fetchCount
        XCTAssertEqual(fetched, 1, "warm-up must trigger a fetch so the stream connects early")
    }

    // MARK: Deferred shutdown (keep-warm grace period)

    func testStopDoesNotShutDownSourceImmediately() async throws {
        let spy = SpyVehicleSource()
        let vm = LiveMapViewModel(source: spy, stops: [], stopNames: [:])
        vm.idleShutdownDelay = 0.5
        vm.stop()
        try await Task.sleep(nanoseconds: 100_000_000)
        let count = await spy.shutdownCount
        XCTAssertEqual(count, 0, "closing the map must keep the socket warm for the grace period")
    }

    func testStopShutsDownSourceAfterIdleDelay() async throws {
        let spy = SpyVehicleSource()
        let vm = LiveMapViewModel(source: spy, stops: [], stopNames: [:])
        vm.idleShutdownDelay = 0.2
        vm.stop()
        try await Task.sleep(nanoseconds: 700_000_000)
        let count = await spy.shutdownCount
        XCTAssertEqual(count, 1, "an idle socket must eventually be closed (battery/data)")
    }

    func testNewViewModelCancelsPreviousViewModelsPendingShutdown() async throws {
        // Each map open creates a fresh @StateObject view model on the SAME
        // shared source — the reopened map must rescue the socket from the
        // previous view model's scheduled shutdown.
        let spy = SpyVehicleSource()
        let vm1 = LiveMapViewModel(source: spy, stops: [], stopNames: [:])
        vm1.idleShutdownDelay = 0.3
        vm1.stop()
        let vm2 = LiveMapViewModel(source: spy, stops: [], stopNames: [:])
        vm2.start()
        try await Task.sleep(nanoseconds: 700_000_000)
        let count = await spy.shutdownCount
        XCTAssertEqual(count, 0, "a reopened map must not have its socket closed by the old view model")
        vm2.stop()
    }

    func testRestartWithinIdleDelayCancelsPendingShutdown() async throws {
        let spy = SpyVehicleSource()
        let vm = LiveMapViewModel(source: spy, stops: [], stopNames: [:])
        vm.idleShutdownDelay = 0.3
        vm.stop()
        try await Task.sleep(nanoseconds: 100_000_000)
        vm.start()
        try await Task.sleep(nanoseconds: 600_000_000)
        let count = await spy.shutdownCount
        XCTAssertEqual(count, 0, "reopening the map within the grace period must keep the socket")
        vm.stop()
    }
}
