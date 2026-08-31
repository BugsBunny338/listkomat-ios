import XCTest
import CoreLocation
@testable import Listkomat

/// Records lifecycle calls so tests can assert how the view model and the
/// shared-source registry treat a live source (#12: eager connect + warm socket;
/// #31: launch prefetch + retained positions).
private actor SpyVehicleSource: VehicleSource {
    nonisolated let maintainsConnection: Bool
    private(set) var fetchCount = 0
    private(set) var shutdownCount = 0
    private var live: [Vehicle] = []
    private var retained: [Vehicle] = []
    private var failing = false
    private var fetchDelay: TimeInterval = 0

    init(maintainsConnection: Bool = true) {
        self.maintainsConnection = maintainsConnection
    }

    func setLive(_ vehicles: [Vehicle]) { live = vehicles }
    func setRetained(_ vehicles: [Vehicle]) { retained = vehicles }
    func setFailing(_ value: Bool) { failing = value }
    /// Holds `fetch()` open so a test can observe what the map shows *before*
    /// live data lands — the whole window #31 is about.
    func setFetchDelay(_ seconds: TimeInterval) { fetchDelay = seconds }

    func fetch() async throws -> [Vehicle] {
        fetchCount += 1
        if fetchDelay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(fetchDelay * 1_000_000_000))
        }
        if failing { throw VehicleSourceError.httpStatus(500) }
        return live
    }
    func shutdown() { shutdownCount += 1 }
    func retainedVehicles() -> [Vehicle] { retained }
}

private func testVehicle(_ id: String, line: String = "1") -> Vehicle {
    Vehicle(id: id,
            coordinate: CLLocationCoordinate2D(latitude: 49.195, longitude: 16.607),
            bearing: nil, line: line, kind: .tram, updatedAt: Date(),
            destinationId: nil, destinationName: nil)
}

@MainActor
final class LiveMapViewModelTests: XCTestCase {

    override func setUp() {
        super.setUp()
        LiveSources.reset()
        LiveSources.idleShutdownDelay = 0.5
    }

    override func tearDown() {
        LiveSources.reset()
        super.tearDown()
    }

    private func makeVM(_ source: VehicleSource) -> LiveMapViewModel {
        LiveMapViewModel(source: source, stops: [], stopNames: [:])
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

    // MARK: Keep-warm from the city screen (eager connect, bounded lifetime)

    func testKeepWarmConnectsThenReleasesAfterLeavingTheScreen() async throws {
        let spy = SpyVehicleSource()
        LiveSources.inject(spy, for: "brno")
        let screen = Task { await LiveSources.keepWarm(cityKey: "brno") }
        try await Task.sleep(nanoseconds: 200_000_000)
        let fetched = await spy.fetchCount
        XCTAssertGreaterThanOrEqual(fetched, 1, "warm-up must connect the stream early")
        let closedWhileVisible = await spy.shutdownCount
        XCTAssertEqual(closedWhileVisible, 0)
        screen.cancel()   // user leaves the city screen without opening the map
        try await Task.sleep(nanoseconds: 1_500_000_000)
        let closed = await spy.shutdownCount
        XCTAssertEqual(closed, 1,
                       "a socket opened by warm-up must be released after the grace period")
    }

    func testKeepWarmSkipsSourcesWithoutAConnection() async throws {
        let spy = SpyVehicleSource(maintainsConnection: false)   // Prague-like poller
        LiveSources.inject(spy, for: "praha")
        let screen = Task { await LiveSources.keepWarm(cityKey: "praha") }
        try await Task.sleep(nanoseconds: 200_000_000)
        screen.cancel()
        let fetched = await spy.fetchCount
        XCTAssertEqual(fetched, 0, "warming a stateless poller is a wasted full-payload fetch")
    }

    // MARK: Interest counting across screens

    func testOpeningTheMapRescuesTheSocketFromTheLeavingCityScreen() async throws {
        // Pushing the map can cancel the city screen's keep-warm AFTER the map's
        // start() — the socket must survive either ordering.
        let spy = SpyVehicleSource()
        LiveSources.inject(spy, for: "brno")
        let screen = Task { await LiveSources.keepWarm(cityKey: "brno") }
        try await Task.sleep(nanoseconds: 150_000_000)
        let vm = makeVM(spy)
        vm.start()
        screen.cancel()
        try await Task.sleep(nanoseconds: 1_200_000_000)
        let closed = await spy.shutdownCount
        XCTAssertEqual(closed, 0, "the open map holds interest — the socket must stay up")
        vm.stop()
    }

    func testStopKeepsSocketWarmThenReleasesAfterGrace() async throws {
        let spy = SpyVehicleSource()
        let vm = makeVM(spy)
        vm.start()
        vm.stop()
        try await Task.sleep(nanoseconds: 150_000_000)
        let early = await spy.shutdownCount
        XCTAssertEqual(early, 0, "closing the map must keep the socket warm for the grace period")
        try await Task.sleep(nanoseconds: 1_200_000_000)
        let late = await spy.shutdownCount
        XCTAssertEqual(late, 1, "an idle socket must eventually be closed (battery/data)")
    }

    // MARK: App backgrounding (central, interest-independent close)

    func testBackgroundingClosesSocketDespiteKeepWarmInterest() async throws {
        // SwiftUI does not cancel .task on scenePhase changes — the central
        // background close must not be blocked by a screen's standing interest.
        let spy = SpyVehicleSource()
        LiveSources.inject(spy, for: "brno")
        let screen = Task { await LiveSources.keepWarm(cityKey: "brno") }
        try await Task.sleep(nanoseconds: 150_000_000)
        LiveSources.closeAllForBackground()
        try await Task.sleep(nanoseconds: 300_000_000)
        let closed = await spy.shutdownCount
        XCTAssertEqual(closed, 1, "backgrounding must close the socket even while a screen holds interest")
        screen.cancel()
    }

    func testBackgroundingClosesSocketUnderOpenMap() async throws {
        let spy = SpyVehicleSource()
        LiveSources.inject(spy, for: "brno")
        let vm = makeVM(LiveSources.source(for: "brno"))
        vm.start()
        LiveSources.closeAllForBackground()
        try await Task.sleep(nanoseconds: 300_000_000)
        let closed = await spy.shutdownCount
        XCTAssertEqual(closed, 1, "backgrounding from the map must close the socket immediately")
        vm.stop()
    }

    func testBackgroundCloseOrphansPendingGraceShutdown() async throws {
        // A grace shutdown scheduled before backgrounding must not fire a
        // second close after the central one already ran.
        let spy = SpyVehicleSource()
        LiveSources.inject(spy, for: "brno")
        let vm = makeVM(LiveSources.source(for: "brno"))
        vm.start()
        vm.stop()   // schedules the 0.5 s grace shutdown
        LiveSources.closeAllForBackground()
        try await Task.sleep(nanoseconds: 1_200_000_000)
        let closed = await spy.shutdownCount
        XCTAssertEqual(closed, 1, "the pending grace shutdown must be orphaned by the background close")
    }

    // MARK: Deinit backstop

    func testViewModelDeinitReleasesInterest() async throws {
        // SwiftUI can discard a @StateObject without firing onDisappear; the
        // view model must not take its interest to the grave.
        let spy = SpyVehicleSource()
        var vm: LiveMapViewModel? = makeVM(spy)
        vm?.start()
        try await Task.sleep(nanoseconds: 100_000_000)
        vm = nil
        try await Task.sleep(nanoseconds: 1_200_000_000)
        let closed = await spy.shutdownCount
        XCTAssertEqual(closed, 1, "a deallocated view model must release its interest")
    }

    func testNewViewModelRescuesSocketFromPreviousViewModelsRelease() async throws {
        // Each map open creates a fresh @StateObject view model on the SAME
        // shared source — the reopened map must rescue the socket from the
        // previous view model's scheduled shutdown.
        let spy = SpyVehicleSource()
        let vm1 = makeVM(spy)
        vm1.start()
        vm1.stop()
        let vm2 = makeVM(spy)
        vm2.start()
        try await Task.sleep(nanoseconds: 1_200_000_000)
        let closed = await spy.shutdownCount
        XCTAssertEqual(closed, 0, "a reopened map must not have its socket closed by the old view model")
        vm2.stop()
    }

    func testRepeatedStartDoesNotLeakInterest() async throws {
        // onAppear and a scenePhase change can both call start(); the interest
        // count must not double, or the socket would never be released.
        let spy = SpyVehicleSource()
        let vm = makeVM(spy)
        vm.start()
        vm.start()
        vm.stop()
        try await Task.sleep(nanoseconds: 1_200_000_000)
        let closed = await spy.shutdownCount
        XCTAssertEqual(closed, 1, "double start() must not leave the socket retained forever")
    }

    // MARK: Retained positions (#31 — grey now, colour when the burst lands)

    func testRetainedPositionsPaintBeforeTheFirstLiveFetchReturns() async throws {
        let spy = SpyVehicleSource()
        await spy.setRetained([testVehicle("a"), testVehicle("b")])
        await spy.setFetchDelay(5)   // the ~30 s wait for the next KORDIS burst
        let vm = makeVM(spy)
        vm.start()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(vm.vehicles.count, 2,
                       "a cold open must show the fleet we still hold, not a spinner")
        XCTAssertTrue(vm.showsRetainedPositions)
        XCTAssertFalse(vm.didLoadOnce, "nothing live has arrived yet")
        vm.stop()
    }

    func testFirstLiveFetchReplacesRetainedPositionsWholesale() async throws {
        let spy = SpyVehicleSource()
        await spy.setRetained([testVehicle("gone"), testVehicle("still-here")])
        await spy.setLive([testVehicle("still-here")])
        let vm = makeVM(spy)
        vm.start()
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(vm.vehicles.map(\.id), ["still-here"],
                       "a retained vehicle that has gone inactive must not linger as a ghost")
        XCTAssertFalse(vm.showsRetainedPositions, "live data must clear the grey treatment")
        vm.stop()
    }

    func testRetainedPositionsStayOnScreenThroughAFailedColdOpen() async throws {
        let spy = SpyVehicleSource()
        await spy.setRetained([testVehicle("a")])
        await spy.setFailing(true)
        let vm = makeVM(spy)
        vm.start()
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(vm.vehicles.count, 1,
                       "the last known fleet under the failure banner beats an empty map")
        XCTAssertTrue(vm.loadFailed)
        XCTAssertTrue(vm.showsRetainedPositions,
                      "a failed fetch must not silently promote retained positions to live")
        vm.stop()
    }

    func testRestartDoesNotReplaceLiveDataWithRetainedPositions() async throws {
        // onAppear and scenePhase both call start(); returning to a map that is
        // already live must not grey it out again.
        let spy = SpyVehicleSource()
        await spy.setLive([testVehicle("live")])
        await spy.setRetained([testVehicle("old")])
        let vm = makeVM(spy)
        vm.start()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(vm.showsRetainedPositions)
        vm.start()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(vm.vehicles.map(\.id), ["live"])
        XCTAssertFalse(vm.showsRetainedPositions)
        vm.stop()
    }

    func testMapWithNoRetainedPositionsStillShowsTheConnectingState() async throws {
        let spy = SpyVehicleSource()
        await spy.setFetchDelay(5)
        let vm = makeVM(spy)
        vm.start()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(vm.vehicles.isEmpty)
        XCTAssertFalse(vm.showsRetainedPositions,
                       "with nothing held, the view must fall through to the connecting card")
        vm.stop()
    }

    // MARK: Launch prefetch (#31 — one burst, then let go)

    func testPrefetchFillsTheSnapshotThenReleasesTheSocket() async throws {
        let spy = SpyVehicleSource()
        LiveSources.inject(spy, for: "brno")
        LiveSources.prefetch(cityKey: "brno")
        try await Task.sleep(nanoseconds: 400_000_000)
        let fetched = await spy.fetchCount
        XCTAssertGreaterThanOrEqual(fetched, 1,
                                    "prefetch must connect before the user asks for the map")
        let closed = await spy.shutdownCount
        XCTAssertEqual(closed, 1,
                       "one burst, then let go — a held socket costs ~320 KB every ~30 s")
    }

    func testPrefetchLeavesTheSocketToAScreenThatTookInterest() async throws {
        let spy = SpyVehicleSource()
        LiveSources.inject(spy, for: "brno")
        let screen = Task { await LiveSources.keepWarm(cityKey: "brno") }
        try await Task.sleep(nanoseconds: 150_000_000)
        LiveSources.prefetch(cityKey: "brno")
        try await Task.sleep(nanoseconds: 400_000_000)
        let closed = await spy.shutdownCount
        XCTAssertEqual(closed, 0, "prefetch must not close a socket a live screen is using")
        screen.cancel()
    }

    func testPrefetchSkipsSourcesWithoutAConnection() async throws {
        let spy = SpyVehicleSource(maintainsConnection: false)   // Prague-like poller
        LiveSources.inject(spy, for: "praha")
        LiveSources.prefetch(cityKey: "praha")
        try await Task.sleep(nanoseconds: 300_000_000)
        let fetched = await spy.fetchCount
        XCTAssertEqual(fetched, 0,
                       "Prague's first fetch already paints the full map — nothing to prefetch")
    }

    func testPrefetchCooldownPreventsASecondBurst() async throws {
        let spy = SpyVehicleSource()
        LiveSources.inject(spy, for: "brno")
        LiveSources.prefetch(cityKey: "brno")
        try await Task.sleep(nanoseconds: 400_000_000)
        LiveSources.prefetch(cityKey: "brno")   // a quick background/foreground cycle
        try await Task.sleep(nanoseconds: 300_000_000)
        let fetched = await spy.fetchCount
        XCTAssertEqual(fetched, 1,
                       "foreground churn must not buy a fresh ~320 KB burst each time")
    }
}
