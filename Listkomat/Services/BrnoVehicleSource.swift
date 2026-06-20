import Foundation
import CoreLocation

/// Decoding + URL logic for Brno's keyless KORDIS ArcGIS vehicle feed.
/// Kept as static functions so they're unit-testable without the network.
///
/// VType codes (sampled live 2026-06-19): 0 = tram (lines 1–12),
/// 1 = trolleybus (25–39), 2 & 4 = bus (city + regional), 5 = train (S/R lines).
enum BrnoVehicleSource {
    // MARK: Decode

    private struct FeatureCollection: Decodable { let features: [Feature] }
    private struct Feature: Decodable { let geometry: Geo; let properties: Props }
    private struct Geo: Decodable { let coordinates: [Double] }   // [lng, lat]
    private struct Props: Decodable {
        let LineName: String
        let Bearing: Double
        let TimeUpdated: Double      // epoch milliseconds
        let IsInactive: String       // "true" / "false" (string in the feed)
        let VType: Int
        let ID: Int
        let FinalStopID: Int?        // destination stop (numeric KORDIS id)
    }

    /// Decode the ArcGIS GeoJSON, dropping inactive vehicles.
    static func decode(_ data: Data) throws -> [Vehicle] {
        let fc = try JSONDecoder().decode(FeatureCollection.self, from: data)
        return fc.features.compactMap { f -> Vehicle? in
            guard f.properties.IsInactive != "true",
                  f.geometry.coordinates.count == 2 else { return nil }
            return Vehicle(
                id: String(f.properties.ID),
                coordinate: CLLocationCoordinate2D(
                    latitude: f.geometry.coordinates[1],
                    longitude: f.geometry.coordinates[0]),
                bearing: f.properties.Bearing >= 0 ? f.properties.Bearing : nil,
                line: f.properties.LineName,
                kind: kind(forVType: f.properties.VType),
                updatedAt: Date(timeIntervalSince1970: f.properties.TimeUpdated / 1000),
                destinationId: (f.properties.FinalStopID ?? 0) > 0 ? f.properties.FinalStopID : nil)
        }
    }

    static func kind(forVType v: Int) -> VehicleKind {
        switch v {
        case 0: return .tram
        case 1: return .trolleybus
        case 5: return .train
        default: return .bus      // 2, 4, and any future code
        }
    }

    // MARK: Layer URL (annual rollover)

    /// The ArcGIS layer name encodes the year and rolls over every January.
    static func layerName(year: Int) -> String { "Kordis_\(year % 100)_polohy" }

    /// Live GeoJSON query URL for the current year's layer.
    ///
    /// `orderByFields=TimeUpdated DESC` is essential: the plain `where=1=1`
    /// response is served from a long-TTL CDN cache (positions never advance),
    /// but this ordered variant returns genuinely live data — and conveniently
    /// puts the freshest vehicles first (so the on-screen cap keeps recent ones).
    static func currentQueryURL(now: Date = Date(),
                                calendar: Calendar = Calendar(identifier: .gregorian)) -> URL {
        let year = calendar.component(.year, from: now)
        let base = "https://gis.brno.cz/ags1/rest/services/Hosted/"
            + "\(layerName(year: year))/FeatureServer/0/query"
        // Only the 7 properties we decode (geometry is always returned for geojson).
        // TimeUpdated must stay — orderByFields sorts on it.
        let fields = "ID%2CBearing%2CLineName%2CVType%2CIsInactive%2CTimeUpdated%2CFinalStopID"
        return URL(string: "\(base)?where=1%3D1&outFields=\(fields)&orderByFields=TimeUpdated%20DESC&f=geojson")!
    }
}

/// Live Brno source: fetches the current layer and decodes it.
struct BrnoLiveSource: VehicleSource {
    var session: URLSession = .shared

    func fetch() async throws -> [Vehicle] {
        // Same URL every poll, so bypass the cache or we'd get stale (static) data.
        var req = URLRequest(url: BrnoVehicleSource.currentQueryURL())
        req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let (data, _) = try await session.data(for: req)
        return try BrnoVehicleSource.decode(data)
    }
}
