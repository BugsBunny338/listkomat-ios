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

    /// True when this city has a live map ("Živá mapa").
    var showsLiveMap: Bool {
        // Prague's live map ships *client-side*: this binary has PragueVehicleSource,
        // so it enables Praha itself rather than via the catalog flag. Crucially, the
        // catalog's `hasLiveMap` for Praha stays unset — so older App Store builds
        // (which lack PragueVehicleSource and would fall back to the Brno source) never
        // show a broken Prague map. Brno continues to gate on the catalog flag.
        if key == "praha" { return true }
        return hasLiveMap == true
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lng)
    }
}
