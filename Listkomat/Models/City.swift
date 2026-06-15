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

    var id: String { key }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lng)
    }
}
