import CoreLocation

/// A transit stop/station. Static data, bundled in the app (Resources/brno-stops.json,
/// produced by scripts/generate-brno-stops.sh). CC-BY 4.0, data.Brno / KORDIS JMK.
struct Stop: Identifiable, Decodable {
    let id: String
    let name: String
    let lat: Double
    let lng: Double

    var coordinate: CLLocationCoordinate2D { .init(latitude: lat, longitude: lng) }
}
