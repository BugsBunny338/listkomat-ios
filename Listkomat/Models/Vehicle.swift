import CoreLocation

/// Kind of transit vehicle, for tinting the map marker.
enum VehicleKind: String {
    case tram, trolleybus, bus, train
}

/// A live transit vehicle position, normalized across data sources (Brno now,
/// Prague later). See docs/plans/2026-06-18-listkomat-v2-live-map-design.md
struct Vehicle: Identifiable, Equatable {
    let id: String
    let coordinate: CLLocationCoordinate2D
    let bearing: Double?      // nil when unknown (the feed sends -1)
    let line: String          // "1", "258"
    let kind: VehicleKind
    let updatedAt: Date

    static func == (a: Vehicle, b: Vehicle) -> Bool {
        a.id == b.id
            && a.coordinate.latitude == b.coordinate.latitude
            && a.coordinate.longitude == b.coordinate.longitude
            && a.bearing == b.bearing
    }
}
