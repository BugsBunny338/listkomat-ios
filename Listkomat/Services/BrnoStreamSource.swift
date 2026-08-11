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

    func vehicles(now: Date = Date(),
                  fresherThan limit: TimeInterval = BrnoVehicleSource.freshnessLimit) -> [Vehicle] {
        byId.values.filter { now.timeIntervalSince($0.updatedAt) <= limit }
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
    private var snapshot = BrnoStreamSnapshot()
    private var applyCount = 0
    private let session: URLSession

    init(session: URLSession = .shared) { self.session = session }

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
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    // MARK: Connection

    private func ensureConnected() async throws {
        if let task, task.state == .running { return }
        task?.cancel(with: .goingAway, reason: nil)
        let t = session.webSocketTask(with: Self.currentStreamURL())
        t.resume()
        do {
            // Await the first message inline: fails fast when unreachable, and
            // guarantees the very first fetch already has data to show. The
            // feed sends many messages per second, so 10 s means "down".
            try apply(await nextMessage(t, timeout: 10))
        } catch {
            t.cancel(with: .goingAway, reason: nil)
            throw error
        }
        // Seed from the initial burst so the first fetch paints a populated map
        // instead of flashing "Žádná vozidla v okolí" until the next poll.
        let deadline = Date().addingTimeInterval(1.5)
        while Date() < deadline, snapshot.storedCount < 100,
              let msg = try? await nextMessage(t, timeout: max(0.05, deadline.timeIntervalSinceNow)) {
            apply(msg)
        }
        task = t
        receiveLoop(on: t)
    }

    private func nextMessage(_ t: URLSessionWebSocketTask,
                             timeout: TimeInterval) async throws -> URLSessionWebSocketTask.Message {
        try await withThrowingTaskGroup(of: URLSessionWebSocketTask.Message.self) { group in
            group.addTask { try await t.receive() }
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
                    await self?.apply(msg)
                } catch {
                    await self?.connectionLost(t)   // next fetch reconnects
                    return
                }
            }
        }
    }

    private func apply(_ msg: URLSessionWebSocketTask.Message) {
        let data: Data?
        switch msg {
        case .string(let s): data = Data(s.utf8)
        case .data(let d): data = d
        @unknown default: data = nil
        }
        // A malformed message is dropped, not fatal — the stream keeps flowing.
        guard let data, let update = try? BrnoStreamDecoder.decode(data) else { return }
        snapshot.apply(update)
        applyCount += 1
        if applyCount.isMultiple(of: 512) { snapshot.prune() }
    }

    private func connectionLost(_ t: URLSessionWebSocketTask) {
        if task === t { task = nil }
    }
}
