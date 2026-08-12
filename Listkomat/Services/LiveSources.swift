import Foundation

/// Per-city live vehicle sources, shared across map opens (#12): Brno's
/// WebSocket accumulates vehicles only as each one reports, so a fresh source
/// per map view meant a sparse map for the first tens of seconds. Sharing the
/// instance keeps the accumulated snapshot (and the socket, until the view
/// model's idle grace period ends) across close/reopen.
@MainActor
enum LiveSources {
    private static var cache: [String: VehicleSource] = [:]

    /// The live source for a city — one instance per city for the app's lifetime.
    static func source(for cityKey: String) -> VehicleSource {
        if let existing = cache[cityKey] { return existing }
        let made = makeSource(for: cityKey)
        cache[cityKey] = made
        return made
    }

    /// Eagerly connect a city's source before the map is opened (from the city
    /// screen), so the stream is already accumulating vehicles when the user
    /// taps "Živá mapa". Failures are ignored — the map's own poll loop is the
    /// path that reports them.
    static func warmUp(cityKey: String) async {
        _ = try? await source(for: cityKey).fetch()
    }

    private static func makeSource(for cityKey: String) -> VehicleSource {
        switch cityKey {
        case "praha": return PragueLiveSource()
        default: return BrnoStreamSource()   // "brno"
        }
    }

    // MARK: Idle shutdown (keep-warm grace period)

    /// Pending idle shutdowns, keyed by source identity — NOT stored on the view
    /// model: every map open creates a fresh @StateObject view model on the same
    /// shared source, and the new one must be able to rescue the socket from the
    /// shutdown its predecessor scheduled.
    private static var pendingShutdowns: [ObjectIdentifier: Task<Void, Never>] = [:]

    /// Release `source`'s connection after `delay` — unless the source is
    /// retaken (map reopened) first.
    static func scheduleShutdown(of source: VehicleSource, after delay: TimeInterval) {
        let key = ObjectIdentifier(source)
        pendingShutdowns[key]?.cancel()
        pendingShutdowns[key] = Task {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await source.shutdown()
        }
    }

    static func cancelPendingShutdown(of source: VehicleSource) {
        let key = ObjectIdentifier(source)
        pendingShutdowns[key]?.cancel()
        pendingShutdowns[key] = nil
    }

    // MARK: Test seams

    static func inject(_ source: VehicleSource, for cityKey: String) { cache[cityKey] = source }

    static func reset() {
        cache.removeAll()
        pendingShutdowns.values.forEach { $0.cancel() }
        pendingShutdowns.removeAll()
    }
}
