import Foundation
import CoreLocation

/// Decoding for Brno's GeoEvent WebSocket vehicle stream — the successor of the
/// Kordis FeatureServer feed, which was retired upstream on 2026-08-10 (#6).
/// One JSON object per message. Attribute semantics match the old layer
/// (VType codes verified against 400 live messages 2026-08-11); the stream
/// additionally carries `Delay` in minutes.
enum BrnoStreamDecoder {
    private struct Message: Decodable { let geometry: Geo; let attributes: Attrs }
    private struct Geo: Decodable { let x: Double; let y: Double }   // x = lng, y = lat
    private struct Attrs: Decodable {
        let ID: Int
        let VType: Int
        let Bearing: Double
        let LineName: String
        let IsInactive: String       // "true" / "false" (string, as in the old feed)
        let TimeUpdated: Double      // epoch milliseconds
        let FinalStopID: Int?
        let Delay: Double?
    }

    /// One stream message applied to the vehicle set: `vehicle == nil` means
    /// remove — the vehicle went inactive or left the area.
    struct Update {
        let id: String
        let vehicle: Vehicle?
    }

    static func decode(_ data: Data,
                       bbox: BrnoVehicleSource.BoundingBox? = .brnoArea) throws -> Update {
        let m = try JSONDecoder().decode(Message.self, from: data)
        let id = String(m.attributes.ID)
        guard m.attributes.IsInactive != "true" else { return Update(id: id, vehicle: nil) }
        if let bbox, !bbox.contains(lat: m.geometry.y, lng: m.geometry.x) {
            return Update(id: id, vehicle: nil)
        }
        return Update(id: id, vehicle: Vehicle(
            id: id,
            coordinate: CLLocationCoordinate2D(latitude: m.geometry.y, longitude: m.geometry.x),
            bearing: m.attributes.Bearing >= 0 ? m.attributes.Bearing : nil,
            line: m.attributes.LineName,
            kind: BrnoVehicleSource.kind(forVType: m.attributes.VType),
            updatedAt: Date(timeIntervalSince1970: m.attributes.TimeUpdated / 1000),
            destinationId: (m.attributes.FinalStopID ?? 0) > 0 ? m.attributes.FinalStopID : nil,
            destinationName: nil,    // Brno resolves destinationId → name in the view
            delay: m.attributes.Delay))
    }
}

/// Latest known position per vehicle, accumulated from stream messages between
/// the view model's polls. Freshness is applied at read time (positions age
/// while the socket is quiet); `prune` bounds the dictionary long-term.
struct BrnoStreamSnapshot {
    private var byId: [String: Vehicle] = [:]

    var storedCount: Int { byId.count }

    mutating func apply(_ update: BrnoStreamDecoder.Update) {
        byId[update.id] = update.vehicle      // nil removes the entry
    }

    /// Freshest first — the map view caps markers with prefix(N), which must
    /// keep the most recently updated vehicles (as the old TimeUpdated DESC
    /// query ordering did), not an arbitrary dictionary-order subset.
    func vehicles(now: Date = Date(),
                  fresherThan limit: TimeInterval = BrnoVehicleSource.freshnessLimit) -> [Vehicle] {
        byId.values.filter { now.timeIntervalSince($0.updatedAt) <= limit }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Evict entries that stopped updating (e.g. vehicles that vanished without
    /// an IsInactive message) so the dictionary doesn't grow without bound.
    mutating func prune(now: Date = Date(), olderThan limit: TimeInterval = 600) {
        byId = byId.filter { now.timeIntervalSince($0.value.updatedAt) <= limit }
    }
}

/// Live Brno source backed by the GeoEvent WebSocket stream. The receive loop
/// fills the snapshot continuously; `fetch()` (re)connects as needed and returns
/// the current snapshot — the view model's 8 s poll loop doubles as the
/// reconnect/backoff mechanism, so failures surface exactly like the old
/// polling source (throw → "Živá data dočasně nedostupná").
actor BrnoStreamSource: VehicleSource {
    private var task: URLSessionWebSocketTask?
    private var connectTask: Task<Void, Error>?   // de-dupes reentrant connects
    private var snapshot = BrnoStreamSnapshot()
    private var applyCount = 0
    private var decodeFailureStreak = 0
    private let session: URLSession
    /// When the socket last delivered anything — drives the stall check.
    private var lastMessageAt = Date.distantPast

    /// Consecutive undecodable messages that force a reconnect. A reconnect's
    /// first message is decoded strictly, so persistent schema drift surfaces
    /// as a failed fetch (toast) instead of a silently empty map.
    static let decodeFailureCutoff = 25

    init(session: URLSession = .shared) { self.session = session }

    /// The socket accumulates the vehicle set between fetches — worth warming.
    nonisolated var maintainsConnection: Bool { true }

    /// Connect-only warm-up: skips `fetch()`'s snapshot build (filter + sort of
    /// the whole vehicle dictionary), which keep-warm would just discard.
    func warmUp() async { try? await ensureConnected() }

    // MARK: Stream URL

    /// The year-less stream KORDIS actually feeds. Upstream history, so the next
    /// break is diagnosable: the `Kordis_26_polohy` FeatureServer went 404 on
    /// 2026-08-10 (#6) → `stream_kordis_26`, which itself went silent on
    /// 2026-08-29 (still listed by /ags4/rest/services, upgrade accepted, but
    /// zero messages in 90 s and the server then closes the socket). There is no
    /// annual rollover any more — this name carries no year.
    ///
    /// If it breaks again, list the live candidates with
    /// `curl 'https://gis.brno.cz/ags4/rest/services?f=json'` and connect to each
    /// `/geoevent/ws/services/<name>/StreamServer/subscribe` — being registered
    /// there does NOT mean it carries data.
    static let streamName = "Kordis_stream"

    /// The dataset docs print an https://gis.brno.cz/ags4/rest/… URL, but that
    /// form rejects the WebSocket upgrade — only this /geoevent/ws/ path works.
    /// The `/subscribe` suffix is required: the URL the service metadata
    /// advertises (bare `/StreamServer`) upgrades fine but never sends anything.
    static func currentStreamURL() -> URL {
        URL(string: "wss://gis.brno.cz/geoevent/ws/services/"
            + "\(streamName)/StreamServer/subscribe")!
    }

    /// How long to wait for the first message before calling the stream dead.
    ///
    /// Must stay comfortably above the feed's batch period: KORDIS does not
    /// stream continuously — it emits the full ~330-vehicle snapshot in one
    /// burst every ~28 s (measured 27.9/27.9/27.9 s on 2026-08-29). Connecting
    /// just after a burst means waiting nearly a full period for the next one,
    /// so the old 10 s deadline failed the fetch on a perfectly healthy stream.
    static let firstMessageTimeout: TimeInterval = 40

    /// How long to let a burst drain before the first fetch reads the snapshot,
    /// so the map paints the whole fleet instead of the slice that arrived first.
    /// One burst takes 0.4–2.2 s to deliver (measured 2026-08-29).
    static let burstSettleDelay: TimeInterval = 2.5

    /// Silence on an ESTABLISHED socket that means the feed died under us.
    ///
    /// Sized so the WHOLE recovery fits inside `freshnessLimit` (120 s), not
    /// just its start: detection can lag by up to one poll, and the reconnect
    /// it triggers then blocks `fetch()` for `firstMessageTimeout` before it
    /// can throw. So the budget is
    ///
    ///     stallTimeout + pollInterval + firstMessageTimeout < freshnessLimit
    ///     70 + 8 + 40 = 118 < 120
    ///
    /// which puts the toast on screen while the last positions are still
    /// fresh, instead of leaving stale markers up with no warning for the gap
    /// in between. Still above two missed bursts (~28 s each) so an ordinary
    /// hiccup in the feed doesn't churn the connection.
    /// `testStallBudgetFitsInsideFreshness` pins the arithmetic.
    static let stallTimeout: TimeInterval = 70

    // MARK: VehicleSource

    func fetch() async throws -> [Vehicle] {
        try await ensureConnected()
        return snapshot.vehicles()
    }

    /// How old a retained position may be and still be worth painting greyed.
    ///
    /// Matched to `BrnoStreamSnapshot.prune`'s eviction horizon: past that the
    /// entries are being discarded anyway, so a longer limit would only promise
    /// data that isn't there. Ten minutes of drift is a few hundred metres —
    /// wrong in the detail, right about which lines are running and roughly
    /// where. The socket does NOT survive backgrounding (`closeAllForBackground`)
    /// but the snapshot does, so this is also what stops a map reopened the
    /// next morning from showing last night's fleet.
    static let retainedLimit: TimeInterval = 600

    /// Positions held from an earlier connection, ignoring `freshnessLimit`
    /// (#31). Never merged with live data — the view model replaces this set
    /// wholesale on the first successful fetch, so vehicles that have since
    /// gone inactive can't linger as ghosts.
    func retainedVehicles() -> [Vehicle] {
        snapshot.vehicles(fresherThan: Self.retainedLimit)
    }

    /// Close the socket while the map is off-screen; the next fetch reconnects.
    func shutdown() {
        connectTask?.cancel()
        connectTask = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    // MARK: Connection

    /// Reentrancy-safe: overlapping fetches (e.g. onAppear + scenePhase both
    /// calling start()) share one in-flight connect instead of each opening a
    /// socket and leaking the loser.
    private func ensureConnected() async throws {
        // Join an in-flight connect BEFORE the running-socket shortcut below:
        // the socket is assigned while the burst is still draining, so a fetch
        // that skipped ahead would read a half-filled snapshot and paint a
        // partial fleet for a whole poll interval.
        if let inFlight = connectTask {
            try await inFlight.value
            return
        }
        if let task, task.state == .running, !isStalled { return }
        let inFlight = Task { try await self.openConnection() }
        connectTask = inFlight
        // Clear only OUR attempt: a shutdown mid-connect nils connectTask and a
        // later attempt may already own it, and this one's unwinding must not
        // evict its successor (which would leave the next fetch opening a
        // second socket).
        defer { if connectTask == inFlight { connectTask = nil } }
        try await inFlight.value
    }

    /// True when the socket is up but the feed stopped talking. A silent server
    /// that never closes the connection would otherwise leave `receive()`
    /// blocked forever and `task.state == .running`, so every poll would take
    /// the shortcut above and the map would sit empty (past `freshnessLimit`)
    /// with no toast and no reconnect — exactly the silently-empty map the
    /// strict first decode exists to prevent, just arriving later. Forcing a
    /// reconnect makes the dead feed surface as a failed fetch instead.
    private var isStalled: Bool {
        Date().timeIntervalSince(lastMessageAt) > Self.stallTimeout
    }

    private func openConnection() async throws {
        task?.cancel(with: .goingAway, reason: nil)
        let t = session.webSocketTask(with: Self.currentStreamURL())
        t.resume()
        do {
            // Await the first message inline, decoded STRICTLY: an open socket
            // is NOT proof of a live feed — the retired stream_kordis_26 still
            // accepts the upgrade and then says nothing. Reaching the deadline,
            // failing to parse, or a drifted schema all surface as a failed
            // fetch (toast), never a silently empty map.
            let first = try await firstMessage(t, timeout: Self.firstMessageTimeout)
            guard let data = payload(of: first) else { throw URLError(.cannotParseResponse) }
            snapshot.apply(try BrnoStreamDecoder.decode(data))
            lastMessageAt = Date()
            // Fresh socket, fresh streak. A reconnect forced by
            // `decodeFailureCutoff` would otherwise start at the cutoff, so the
            // first bad frame on the new socket would tear it down again —
            // a reconnect loop driven by one malformed message per burst
            // rather than by real schema drift.
            decodeFailureStreak = 0
        } catch {
            t.cancel(with: .goingAway, reason: nil)
            throw error
        }
        task = t
        receiveLoop(on: t)
        // Let the initial burst land so the first fetch paints a populated map
        // instead of flashing "Žádná vozidla v okolí" until the next poll —
        // which, with a ~28 s batch period, would leave a near-empty map on
        // screen for half a minute.
        try? await Task.sleep(nanoseconds: UInt64(Self.burstSettleDelay * 1_000_000_000))
    }

    private func firstMessage(_ t: URLSessionWebSocketTask,
                              timeout: TimeInterval) async throws -> URLSessionWebSocketTask.Message {
        try await withThrowingTaskGroup(of: URLSessionWebSocketTask.Message.self) { group in
            group.addTask {
                // receive() ignores cooperative cancellation, and the group
                // must await this child before it can exit — cancel the socket
                // itself so the timeout can actually propagate.
                try await withTaskCancellationHandler {
                    try await t.receive()
                } onCancel: {
                    t.cancel(with: .goingAway, reason: nil)
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw URLError(.timedOut)
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    private func receiveLoop(on t: URLSessionWebSocketTask) {
        Task { [weak self] in
            while true {
                do {
                    let msg = try await t.receive()
                    guard let self, await self.accept(msg, from: t) else {
                        t.cancel(with: .goingAway, reason: nil)   // superseded socket — evict
                        return
                    }
                } catch {
                    await self?.connectionLost(t)   // next fetch reconnects
                    return
                }
            }
        }
    }

    /// Apply a message if `t` is still the current socket. Returns false when
    /// this loop's socket was superseded (a race left it orphaned) so the loop
    /// closes it instead of receiving forever.
    private func accept(_ msg: URLSessionWebSocketTask.Message, from t: URLSessionWebSocketTask) -> Bool {
        guard task === t else { return false }
        apply(msg)
        return true
    }

    private func apply(_ msg: URLSessionWebSocketTask.Message) {
        // Anything arriving proves the feed is still talking, decodable or not
        // (persistent garbage is what `decodeFailureCutoff` below is for).
        lastMessageAt = Date()
        // A lone malformed message is dropped, but a persistent streak means
        // schema drift: force a reconnect, whose strict first decode fails the
        // next fetch and shows the failure toast instead of an empty map.
        guard let data = payload(of: msg), let update = try? BrnoStreamDecoder.decode(data) else {
            decodeFailureStreak += 1
            if decodeFailureStreak >= Self.decodeFailureCutoff {
                task?.cancel(with: .goingAway, reason: nil)
                task = nil
            }
            return
        }
        decodeFailureStreak = 0
        snapshot.apply(update)
        applyCount += 1
        if applyCount.isMultiple(of: 512) { snapshot.prune() }
    }

    private func payload(of msg: URLSessionWebSocketTask.Message) -> Data? {
        switch msg {
        case .string(let s): return Data(s.utf8)
        case .data(let d): return d
        @unknown default: return nil
        }
    }

    private func connectionLost(_ t: URLSessionWebSocketTask) {
        if task === t { task = nil }
    }
}
