import Foundation
import CoreLocation

/// A city with its premium-SMS number and the tickets it offers.
struct City: Identifiable, Codable, Hashable {
    let key: String             // stable id, e.g. "praha"
    let name: String            // Czech display name, e.g. "Praha"
    let lat: Double
    let lng: Double
    let smsNumber: String       // premium SMS recipient, e.g. "90206"
    let tickets: [Ticket]
    /// Optional per-language overrides for `name` ("Prague"); absent decodes to nil.
    var i18n: [String: CatalogText]? = nil
    var hasLiveMap: Bool? = nil // catalog flag; absent decodes to nil (Optional tolerates a missing key)
    /// Remote kill switch, absent by default. Prague's map is enabled by the binary
    /// rather than by `hasLiveMap` (see `showsLiveMap`), so clearing that flag can no
    /// longer switch it off; this can, without an app release, if the proxy or the
    /// Golemio key dies. Older builds simply ignore the unknown key — they never
    /// showed the Prague map anyway.
    var liveMapDisabled: Bool? = nil

    var id: String { key }

    /// True when this city has a live map ("Živá mapa").
    var showsLiveMap: Bool {
        if liveMapDisabled == true { return false }
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
