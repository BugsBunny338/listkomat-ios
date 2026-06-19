import Foundation

/// Drives the live map: loads bundled stops once, then polls the vehicle source
/// every ~8 s. Keeps the last positions on failure (sets `loadFailed`).
@MainActor
final class LiveMapViewModel: ObservableObject {
    @Published private(set) var vehicles: [Vehicle] = []
    @Published private(set) var stops: [Stop] = []
    @Published private(set) var loadFailed = false
    @Published private(set) var didLoadOnce = false   // false until the first fetch returns

    private let source: VehicleSource
    private var pollTask: Task<Void, Never>?

    init(source: VehicleSource = BrnoLiveSource()) { self.source = source }

    func start() {
        if stops.isEmpty { stops = StopsStore.brno() }
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: 8_000_000_000)
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
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
