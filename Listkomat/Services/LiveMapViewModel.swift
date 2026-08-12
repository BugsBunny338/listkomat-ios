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
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: 8_000_000_000)
            }
        }
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
            vehicles = try await source.fetch()
            loadFailed = false
        } catch {
            loadFailed = true   // keep last vehicles on screen
        }
        didLoadOnce = true
    }
}
