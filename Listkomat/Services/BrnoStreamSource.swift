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

    /// Consecutive undecodable messages that force a reconnect. A reconnect's
    /// first message is decoded strictly, so persistent schema drift surfaces
    /// as a failed fetch (toast) instead of a silently empty map.
    static let decodeFailureCutoff = 25

    init(session: URLSession = .shared) { self.session = session }

    /// The socket accumulates the vehicle set between fetches — worth warming.
    nonisolated var maintainsConnection: Bool { true }

    // MARK: Stream URL (annual rollover, like the old layer name)

    static func streamName(year: Int) -> String { "stream_kordis_\(year % 100)" }

    /// The dataset docs print an https://gis.brno.cz/ags4/rest/… URL, but that
    /// form rejects the WebSocket upgrade — only this /geoevent/ws/ path works.
    static func currentStreamURL(now: Date = Date(),
                                 calendar: Calendar = Calendar(identifier: .gregorian)) -> URL {
        let year = calendar.component(.year, from: now)
        return URL(string: "wss://gis.brno.cz/geoevent/ws/services/"
            + "\(streamName(year: year))/StreamServer/subscribe")!
    }

    // MARK: VehicleSource

    func fetch() async throws -> [Vehicle] {
        try await ensureConnected()
        return snapshot.vehicles()
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
        if let task, task.state == .running { return }
        let inFlight = connectTask ?? Task { try await self.openConnection() }
        connectTask = inFlight
        try await inFlight.value
    }

    private func openConnection() async throws {
        defer { connectTask = nil }   // runs on the actor at this attempt's end
        task?.cancel(with: .goingAway, reason: nil)
        let t = session.webSocketTask(with: Self.currentStreamURL())
        t.resume()
        do {
            // Await the first message inline, decoded STRICTLY: fails fast when
            // the host is unreachable, the upgrade hangs, or the schema drifted
            // — all surface as a failed fetch (toast), never a silently empty
            // map. The feed sends many messages per second, so 10 s = "down".
            let first = try await firstMessage(t, timeout: 10)
            guard let data = payload(of: first) else { throw URLError(.cannotParseResponse) }
            snapshot.apply(try BrnoStreamDecoder.decode(data))
        } catch {
            t.cancel(with: .goingAway, reason: nil)
            throw error
        }
        task = t
        receiveLoop(on: t)
        // Let the initial burst land so the first fetch paints a populated map
        // instead of flashing "Žádná vozidla v okolí" until the next poll.
        try? await Task.sleep(nanoseconds: 800_000_000)
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
