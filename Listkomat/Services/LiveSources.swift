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
    /// When each released source's grace window expires. Lets the launch
    /// prefetch tell "idle socket nobody wants" from "socket being kept warm for
    /// a reopen", which look identical through `interest` alone.
    private static var graceUntil: [ObjectIdentifier: Date] = [:]

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

    // MARK: Launch prefetch (one burst, then let go)

    /// Seconds before a finished prefetch may run again. Rapid
    /// background/foreground cycling would otherwise buy a fresh burst each
    /// time, and a snapshot this young is still worth painting anyway.
    static var prefetchCooldown: TimeInterval = defaultPrefetchCooldown
    private static let defaultPrefetchCooldown: TimeInterval = 120

    private static var prefetching: Set<String> = []
    private static var lastPrefetchAt: [String: Date] = [:]

    /// Fill a city's snapshot at launch/foreground, before the user has reached
    /// the city screen and before the map is anywhere in sight (#31).
    ///
    /// KORDIS sends nothing on subscribe and then emits the whole fleet in one
    /// burst every ~30 s, so a map opened cold waits for the next burst no
    /// matter how fast we connect. Connecting at launch spends that wait during
    /// seconds the user is spending anyway — and if they never open the map, we
    /// throw the snapshot away, which is the cheap outcome.
    ///
    /// Deliberately ONE burst, not a held-open socket: a burst measures ~320 KB
    /// (807 messages × ~407 B, measured against the live feed 2026-08-31), so
    /// keeping the stream up "just in case" would cost about a megabyte per
    /// launch of data nobody asked for. `warmUp()` already returns only once
    /// the first burst has landed and settled, so the snapshot is complete by
    /// the time this releases it. What the user sees on a later map open is
    /// that snapshot, greyed, courtesy of `retainedVehicles()`.
    ///
    /// Prague needs none of this and gets none: `maintainsConnection` is false
    /// for a stateless poller whose first fetch already paints the full map.
    static func prefetch(cityKey: String) {
        let src = source(for: cityKey)
        guard src.maintainsConnection else { return }
        let key = ObjectIdentifier(src)
        // Only ever act on a socket nobody has an opinion about. A screen may be
        // holding this one, or may have just stepped off it with its keep-warm
        // grace window still running (#12) — in both cases the snapshot is being
        // filled without us, and the shutdown below would throw away exactly the
        // warm reopen that grace period exists to buy.
        guard interest[key, default: 0] == 0, !isInGracePeriod(key) else { return }
        guard !prefetching.contains(cityKey) else { return }
        if let last = lastPrefetchAt[cityKey],
           Date().timeIntervalSince(last) < prefetchCooldown { return }
        prefetching.insert(cityKey)
        Task {
            // Cleared however we leave, so a source that never returns can't
            // wedge prefetch off for this city for the rest of the process.
            defer {
                prefetching.remove(cityKey)
                lastPrefetchAt[cityKey] = Date()
            }
            // Hold interest while filling: a shutdown scheduled elsewhere would
            // otherwise cut the burst in half and leave a partial fleet to paint.
            retain(src)
            // Self-bounding: a dead feed fails on BrnoStreamSource's own
            // first-message deadline rather than hanging here. Failures are
            // silent — the map's poll loop is the only path that reports them.
            await src.warmUp()
            await releaseWithoutGrace(src)
        }
    }

    /// Hand back a prefetch's interest and close the socket if nothing else took
    /// it meanwhile. Unlike `release`, no grace window: this was one burst to
    /// fill the snapshot, not a session anyone is coming back to. A map opened in
    /// the gap reconnects on its own first fetch.
    private static func releaseWithoutGrace(_ source: VehicleSource) async {
        let key = ObjectIdentifier(source)
        interest[key] = max(0, (interest[key] ?? 0) - 1)
        guard interest[key] == 0 else { return }   // a screen took over while we filled
        generation[key, default: 0] += 1           // orphan anything scheduled meanwhile
        graceUntil[key] = nil
        await source.shutdown()
    }

    /// True while a released source is still inside its keep-warm grace window:
    /// nothing holds interest, but the socket is up and spoken for.
    private static func isInGracePeriod(_ key: ObjectIdentifier) -> Bool {
        (graceUntil[key]?.timeIntervalSinceNow ?? 0) > 0
    }

    /// Register interest in `source`, keeping its connection up and invalidating
    /// any scheduled shutdown.
    static func retain(_ source: VehicleSource) {
        let key = ObjectIdentifier(source)
        interest[key, default: 0] += 1
        generation[key, default: 0] += 1
        graceUntil[key] = nil   // the generation bump just orphaned that shutdown
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
        graceUntil[key] = Date().addingTimeInterval(idleShutdownDelay)
        Task {
            try? await Task.sleep(nanoseconds: UInt64(idleShutdownDelay * 1_000_000_000))
            guard generation[key] == gen, interest[key] == 0 else { return }
            graceUntil[key] = nil
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
            let key = ObjectIdentifier(src)
            generation[key, default: 0] += 1
            // The socket is gone, so no grace window is left to protect — without
            // this the foreground prefetch would mistake the stale marker for a
            // live keep-warm and skip the one burst it exists to fetch.
            graceUntil[key] = nil
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
        graceUntil.removeAll()
        idleShutdownDelay = defaultIdleShutdownDelay
        prefetching.removeAll()
        lastPrefetchAt.removeAll()
        prefetchCooldown = defaultPrefetchCooldown
    }
}
