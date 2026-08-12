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

    /// Seconds an idle source is kept warm after `stop()` before its connection
    /// is released (#12). Var for tests.
    var idleShutdownDelay: TimeInterval = 120

    let source: VehicleSource
    private let seedStops: [Stop]
    private let seedStopNames: [Int: String]
    private var pollTask: Task<Void, Never>?

    init(source: VehicleSource, stops: [Stop], stopNames: [Int: String]) {
        self.source = source
        self.seedStops = stops
        self.seedStopNames = stopNames
    }

    /// Build the view model for a city: its shared live source + bundled stops.
    /// Prague has no numeric stop-names map — destinations come from the feed.
    static func make(for city: City) -> LiveMapViewModel {
        switch city.key {
        case "praha":
            return LiveMapViewModel(source: LiveSources.source(for: city.key),
                                    stops: StopsStore.prague(), stopNames: [:])
        default: // "brno"
            return LiveMapViewModel(source: LiveSources.source(for: city.key),
                                    stops: StopsStore.brno(), stopNames: StopNamesStore.brno())
        }
    }

    func start() {
        LiveSources.cancelPendingShutdown(of: source)   // back within the grace period
        if stops.isEmpty { stops = seedStops }
        if stopNames.isEmpty { stopNames = seedStopNames }
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: 8_000_000_000)
            }
        }
    }

    /// Stops polling. The source's connection is kept warm for
    /// `idleShutdownDelay` so a quick reopen paints instantly (#12), then
    /// released — Brno's stream is chatty, so an abandoned socket would keep
    /// burning data.
    func stop() {
        pollTask?.cancel()
        pollTask = nil
        LiveSources.scheduleShutdown(of: source, after: idleShutdownDelay)
    }

    private func refresh() async {
        do {
            vehicles = try await source.fetch()
            loadFailed = false
        } catch {
            loadFailed = true   // keep last vehicles on screen
        }
        didLoadOnce = true
    }
}
