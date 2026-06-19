import Foundation
import CoreLocation

/// A city with its premium-SMS number and the tickets it offers.
struct City: Identifiable, Codable, Hashable {
    let key: String             // stable id, e.g. "praha"
    let name: String            // display name, e.g. "Praha"
    let lat: Double
    let lng: Double
    let smsNumber: String       // premium SMS recipient, e.g. "90206"
    let tickets: [Ticket]
    var hasLiveMap: Bool? = nil // catalog flag; absent decodes to nil (Optional tolerates a missing key)

    var id: String { key }

    /// True when this city has a live map ("Živá mapa") — Brno now, Praha later.
    var showsLiveMap: Bool { hasLiveMap == true }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lng)
    }
}
