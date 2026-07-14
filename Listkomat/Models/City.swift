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
    var showsLiveMap: Bool {
        #if DEBUG
        // Dev-only: preview Prague's live map before the production catalog flip,
        // without exposing it to released App Store builds (which still map any
        // live-map city to the Brno source). Remove once Prague ships for real.
        if key == "praha" { return true }
        #endif
        return hasLiveMap == true
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lng)
    }
}
