import Foundation

/// Source-agnostic supplier of live vehicle positions. Brno (keyless GeoEvent
/// WebSocket) and Prague (GTFS-RT via a caching proxy) conform to the same shape.
/// Class-bound: sources are shared per city (see `LiveSources`) so a live
/// connection survives the map view's lifecycle.
protocol VehicleSource: AnyObject {
    func fetch() async throws -> [Vehicle]
    /// Release any live connection while the map is off-screen. Optional —
    /// polling sources have nothing to release.
    func shutdown() async
}

extension VehicleSource {
    func shutdown() async {}
}

/// Transport-level failure. Thrown rather than decoded, so `LiveMapViewModel`
/// keeps the last positions and flags the failure instead of clearing the map.
enum VehicleSourceError: Error, Equatable {
    /// The endpoint answered with a non-2xx status.
    case httpStatus(Int)
}
