import XCTest
@testable import Listkomat

/// Records lifecycle calls so tests can assert how the view model and the
/// shared-source registry treat a live source (#12: eager connect + warm socket).
private actor SpyVehicleSource: VehicleSource {
    nonisolated let maintainsConnection: Bool
    private let shutdownDuration: TimeInterval
    private(set) var fetchCount = 0
    private(set) var shutdownCount = 0

    init(maintainsConnection: Bool = true, shutdownDuration: TimeInterval = 0) {
        self.maintainsConnection = maintainsConnection
        self.shutdownDuration = shutdownDuration
    }

    func fetch() async throws -> [Vehicle] { fetchCount += 1; return [] }

    func shutdown() async {
        if shutdownDuration > 0 {
            try? await Task.sleep(nanoseconds: UInt64(shutdownDuration * 1_000_000_000))
        }
        shutdownCount += 1
    }
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

    func testStopReleaseNowClosesImmediately() async throws {
        // scenePhase .background — the pre-#12 behavior of closing right away.
        let spy = SpyVehicleSource()
        let vm = makeVM(spy)
        vm.start()
        vm.stop(releaseNow: true)
        try await Task.sleep(nanoseconds: 300_000_000)
        let closed = await spy.shutdownCount
        XCTAssertEqual(closed, 1, "backgrounding must release the socket without the grace period")
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

    func testRetainDuringShutdownHopReconnects() async throws {
        // A retain can land while the release is already inside the source's
        // shutdown (actor hop) — too late to cancel. The registry must heal by
        // reconnecting instead of leaving the live map on a dead socket.
        let spy = SpyVehicleSource(shutdownDuration: 0.3)
        let vm1 = makeVM(spy)
        vm1.start()
        let before = await spy.fetchCount
        vm1.stop(releaseNow: true)              // shutdown starts its 0.3 s hop
        try await Task.sleep(nanoseconds: 100_000_000)
        let vm2 = makeVM(spy)
        vm2.start()                             // lands mid-shutdown
        try await Task.sleep(nanoseconds: 800_000_000)
        let closed = await spy.shutdownCount
        let after = await spy.fetchCount
        XCTAssertEqual(closed, 1)
        XCTAssertGreaterThan(after, before + 1,
                             "a retain racing the shutdown hop must trigger a reconnect fetch")
        vm2.stop()
    }
}
