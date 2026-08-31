import Foundation

/// Drives the live map: loads bundled stops once, then polls the vehicle source
/// every ~8 s. Keeps the last positions on failure (sets `loadFailed`).
@MainActor
final class LiveMapViewModel: ObservableObject {
    @Published private(set) var vehicles: [Vehicle] = []
    @Published private(set) var stops: [Stop] = []
    @Published private(set) var stopNames: [Int: String] = [:]   // FinalStopID → destination name
    @Published private(set) var loadFailed = false
    @Published private(set) var didLoadOnce = false   // false until the first fetch returns
    /// True while `vehicles` holds positions carried over from an earlier
    /// connection rather than a live fetch (#31). Drives the greyed markers and
    /// the "last known positions" banner; cleared by the first successful fetch,
    /// which replaces the whole set at once.
    @Published private(set) var showsRetainedPositions = false

    /// How often the map re-reads the source. Also the worst-case lag between
    /// a stream stalling and the source noticing, which is why
    /// `BrnoStreamSource.stallTimeout` is sized against it — nonisolated so
    /// that budget can be asserted without hopping to the main actor.
    nonisolated static let pollInterval: TimeInterval = 8

    let source: VehicleSource
    private let seedStops: [Stop]
    private let seedStopNames: [Int: String]
    private var pollTask: Task<Void, Never>?
    private var holdsInterest = false

    init(source: VehicleSource, stops: [Stop], stopNames: [Int: String]) {
        self.source = source
        self.seedStops = stops
        self.seedStopNames = stopNames
    }

    deinit {
        // SwiftUI can discard a @StateObject without firing onDisappear —
        // don't take a retained interest (and thus the socket) to the grave.
        pollTask?.cancel()
        if holdsInterest {
            let source = source
            Task { @MainActor in LiveSources.release(source) }
        }
    }

    /// Build the view model for a city: its shared live source + bundled stops.
    /// Prague has no numeric stop-names map — destinations come from the feed.
    /// New live-map cities also need a source kind in `LiveSources.makeSource`.
    static func make(for city: City) -> LiveMapViewModel {
        let source = LiveSources.source(for: city.key)
        switch city.key {
        case "praha":
            return LiveMapViewModel(source: source, stops: StopsStore.prague(), stopNames: [:])
        default: // "brno"
            return LiveMapViewModel(source: source, stops: StopsStore.brno(),
                                    stopNames: StopNamesStore.brno())
        }
    }

    func start() {
        if !holdsInterest {   // onAppear and scenePhase can both call start()
            holdsInterest = true
            LiveSources.retain(source)
        }
        if stops.isEmpty { stops = seedStops }
        if stopNames.isEmpty { stopNames = seedStopNames }
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            await self?.seedFromRetainedPositions()
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: UInt64(Self.pollInterval * 1_000_000_000))
            }
        }
    }

    /// Paint whatever the source still holds from an earlier connection, so a
    /// cold open shows the fleet (greyed) instead of a spinner while the first
    /// burst is in flight (#31). Runs ahead of the first `refresh()` in the same
    /// task, so it can never overwrite live data with older positions.
    private func seedFromRetainedPositions() async {
        guard vehicles.isEmpty else { return }   // a warm reopen already has live data
        let retained = await source.retainedVehicles()
        guard !retained.isEmpty, !didLoadOnce, vehicles.isEmpty else { return }
        vehicles = retained
        showsRetainedPositions = true
    }

    /// Stops polling and drops this view model's interest in the source. With
    /// no interest left, the connection is kept warm for the grace period so a
    /// quick reopen paints instantly (#12), then released — Brno's stream is
    /// chatty, so an abandoned socket would keep burning data. (App
    /// backgrounding is handled centrally by `LiveSources`, not here.)
    func stop() {
        pollTask?.cancel()
        pollTask = nil
        if holdsInterest {
            holdsInterest = false
            LiveSources.release(source)
        }
    }

    private func refresh() async {
        do {
            // Replace, never merge: a retained vehicle that has since gone
            // inactive must disappear, not linger as a ghost that looks live.
            vehicles = try await source.fetch()
            showsRetainedPositions = false
            loadFailed = false
        } catch {
            // Keep the last vehicles on screen — including retained ones, which
            // stay flagged as such. A failed cold open showing the last known
            // fleet under the failure banner beats an empty map.
            loadFailed = true
        }
        didLoadOnce = true
    }
}
