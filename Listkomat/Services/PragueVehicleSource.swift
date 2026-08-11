import Foundation
import CoreLocation

/// Decoding for Prague's PID vehicle feed, delivered as compact JSON by the
/// Lístkomat proxy (which trims Golemio's GeoJSON — no protobuf in the app).
/// Pure static funcs so they're unit-testable without the network.
/// See docs/plans/2026-07-13-listkomat-prague-live-map-b1.md
enum PragueVehicleSource {
    private struct Payload: Decodable { let vehicles: [Wire] }
    private struct Wire: Decodable {
        let id: String
        let lat: Double
        let lng: Double
        let brng: Double?
        let line: String
        let rt: Int
        let ts: String
        let dest: String?
    }

    /// A lat/lng rectangle. MapKit-free so the decoder stays pure/unit-testable.
    struct BoundingBox {
        let minLat, maxLat, minLng, maxLng: Double
        func contains(lat: Double, lng: Double) -> Bool {
            lat >= minLat && lat <= maxLat && lng >= minLng && lng <= maxLng
        }
        /// Generous — PID includes regional trains + the airport bus, so a tight
        /// city box would drop legitimate vehicles. Guards only against garbage coords.
        static let pragueArea = BoundingBox(minLat: 49.4, maxLat: 50.8, minLng: 12.8, maxLng: 15.9)
    }

    /// Drop vehicles whose last report is older than this. The proxy already only
    /// forwards tracked vehicles, so this mainly fades any that briefly go stale.
    static let freshnessLimit: TimeInterval = 180

    /// GTFS `route_type` → marker kind. Prague adds metro (1) and rail (2).
    static func kind(forRouteType rt: Int) -> VehicleKind {
        switch rt {
        case 0: return .tram
        case 1: return .metro
        case 2: return .train
        case 11: return .trolleybus
        default: return .bus      // 3 and any future code
        }
    }

    /// Decode the proxy's compact JSON. `bbox` drops out-of-area coords; `fresherThan`
    /// drops vehicles whose `ts` is older than that many seconds before `now`.
    static func decode(_ data: Data,
                       bbox: BoundingBox? = nil,
                       fresherThan: TimeInterval? = nil,
                       now: Date = Date()) throws -> [Vehicle] {
        // Two parsers: `ISO8601DateFormatter` rejects fractional seconds unless
        // told to expect them, and rejects their absence once told. Upstream stamps
        // arrive in both shapes, and a rejected one used to fall back to `now` —
        // which made the vehicle permanently exempt from the freshness filter.
        let iso = ISO8601DateFormatter()
        let isoFractional = ISO8601DateFormatter()
        isoFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func parse(_ s: String) -> Date? { iso.date(from: s) ?? isoFractional.date(from: s) }

        let payload = try JSONDecoder().decode(Payload.self, from: data)
        return payload.vehicles.compactMap { w -> Vehicle? in
            if let bbox, !bbox.contains(lat: w.lat, lng: w.lng) { return nil }
            let updated = parse(w.ts) ?? now
            if let fresherThan, now.timeIntervalSince(updated) > fresherThan { return nil }
            return Vehicle(
                id: w.id,
                coordinate: CLLocationCoordinate2D(latitude: w.lat, longitude: w.lng),
                bearing: (w.brng ?? -1) >= 0 ? w.brng : nil,
                line: w.line,
                kind: kind(forRouteType: w.rt),
                updatedAt: updated,
                destinationId: nil,
                destinationName: w.dest)
        }
    }
}

/// Live Prague source: fetches the proxy's trimmed JSON and decodes it.
struct PragueLiveSource: VehicleSource {
    /// Proxy base, overridable for tests/staging. Points at the deployed Worker
    /// (see proxy/README.md); the Golemio key lives only in that Worker's secret.
    var endpoint = URL(string: "https://listkomat-proxy.listkomat.workers.dev/prague/vehicles")!
    var session: URLSession = .shared

    func fetch() async throws -> [Vehicle] {
        var req = URLRequest(url: endpoint)
        req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let (data, response) = try await session.data(for: req)
        // The proxy reports an outage as a 502 whose body is a valid, empty payload.
        // Decoding it would silently clear the map; throwing keeps the last
        // positions on screen and lets the view model flag the failure.
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw VehicleSourceError.httpStatus(http.statusCode)
        }
        return try PragueVehicleSource.decode(data, bbox: .pragueArea,
                                              fresherThan: PragueVehicleSource.freshnessLimit)
    }
}
