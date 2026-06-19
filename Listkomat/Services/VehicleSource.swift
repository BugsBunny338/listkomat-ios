import Foundation

/// Source-agnostic supplier of live vehicle positions. Brno (keyless ArcGIS) now;
/// Prague (GTFS-RT via a caching proxy) is v2.1 and will conform to the same shape.
protocol VehicleSource {
    func fetch() async throws -> [Vehicle]
}
