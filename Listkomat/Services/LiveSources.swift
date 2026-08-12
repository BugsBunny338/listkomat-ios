import UIKit

/// Per-city live vehicle sources, shared across map opens (#12): Brno's
/// WebSocket accumulates vehicles only as each one reports, so a fresh source
/// per map view meant a sparse map for the first tens of seconds. Sharing the
/// instance keeps the accumulated snapshot across close/reopen, and interest
/// counting keeps the socket itself warm exactly as long as a screen that
/// benefits from it (city screen or map) is up — plus a grace period.
/// Backgrounding is handled centrally here: one notification observer closes
/// every live connection, so no screen needs its own scenePhase plumbing.
@MainActor
enum LiveSources {
    private static var cache: [String: VehicleSource] = [:]

    /// The live source for a city — one instance per city for the app's lifetime.
    static func source(for cityKey: String) -> VehicleSource {
        installBackgroundObserverIfNeeded()
        if let existing = cache[cityKey] { return existing }
        let made = makeSource(for: cityKey)
        cache[cityKey] = made
        return made
    }

    /// One switch per concern: the source kind lives here, the city's bundled
    /// stops live in `LiveMapViewModel.make(for:)` — add new live-map cities
    /// in BOTH places.
    private static func makeSource(for cityKey: String) -> VehicleSource {
        switch cityKey {
        case "praha": return PragueLiveSource()
        default: return BrnoStreamSource()   // "brno"
        }
    }

    // MARK: Interest counting (keep-warm)

    /// Seconds an idle source is kept warm after its last interest is released
    /// before its connection is closed. Var for tests.
    static var idleShutdownDelay: TimeInterval = defaultIdleShutdownDelay
    private static let defaultIdleShutdownDelay: TimeInterval = 120

    /// Live interest per source identity, plus a generation stamp that
    /// invalidates scheduled shutdowns. Kept here, NOT on the view model:
    /// every map open creates a fresh @StateObject view model on the same
    /// shared source, and a successor must be able to rescue the socket from
    /// the release its predecessor scheduled.
    private static var interest: [ObjectIdentifier: Int] = [:]
    private static var generation: [ObjectIdentifier: Int] = [:]

    /// Keep a city's source connected while the caller's task lives — run from
    /// the city screen via `.task`, so the stream is already accumulating
    /// vehicles when the user taps "Živá mapa". Cancelling the task (leaving
    /// the screen) releases the interest; sources without a live connection
    /// (Prague's stateless poller) are left alone. Failures are ignored — the
    /// map's own poll loop is the path that reports them.
    static func keepWarm(cityKey: String) async {
        let src = source(for: cityKey)
        guard src.maintainsConnection else { return }
        retain(src)
        defer { release(src) }
        while !Task.isCancelled {
            await src.warmUp()   // (re)connect, e.g. after a background close or a drop
            try? await Task.sleep(nanoseconds: 30_000_000_000)
        }
    }

    /// Register interest in `source`, keeping its connection up and invalidating
    /// any scheduled shutdown.
    static func retain(_ source: VehicleSource) {
        let key = ObjectIdentifier(source)
        interest[key, default: 0] += 1
        generation[key, default: 0] += 1
    }

    /// Drop one interest in `source`. When the last interest goes, its
    /// connection is released after the grace period — a raced shutdown under
    /// a just-reopened map self-heals via the map's own poll (fetch reconnects).
    static func release(_ source: VehicleSource) {
        let key = ObjectIdentifier(source)
        interest[key] = max(0, (interest[key] ?? 0) - 1)
        guard interest[key] == 0 else { return }
        generation[key, default: 0] += 1
        let gen = generation[key]
        Task {
            try? await Task.sleep(nanoseconds: UInt64(idleShutdownDelay * 1_000_000_000))
            guard generation[key] == gen, interest[key] == 0 else { return }
            await source.shutdown()
        }
    }

    // MARK: App backgrounding

    /// Close every live connection immediately, regardless of interest — a
    /// screen's .task is NOT cancelled by scenePhase changes, so interest
    /// counts stay up across backgrounding by design. Holders' own fetch
    /// loops (the map's 8 s poll, keepWarm's 30 s tick) reconnect after
    /// foregrounding. Invalidates pending grace shutdowns so none fires a
    /// second close later.
    static func closeAllForBackground() {
        for src in cache.values where src.maintainsConnection {
            generation[ObjectIdentifier(src), default: 0] += 1
            Task { await src.shutdown() }
        }
    }

    private static var backgroundObserverInstalled = false
    private static func installBackgroundObserverIfNeeded() {
        guard !backgroundObserverInstalled else { return }
        backgroundObserverInstalled = true
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil, queue: .main
        ) { _ in
            Task { @MainActor in closeAllForBackground() }
        }
    }

    // MARK: Test seams

    static func inject(_ source: VehicleSource, for cityKey: String) { cache[cityKey] = source }

    static func reset() {
        cache.removeAll()
        // Bumping generations orphans any scheduled shutdown from a previous test.
        for key in generation.keys { generation[key]! += 1 }
        interest.removeAll()
        idleShutdownDelay = defaultIdleShutdownDelay
    }
}
