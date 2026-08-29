import SwiftUI
import CoreLocation

/// Kind of transit vehicle, for tinting the map marker.
enum VehicleKind: String, CaseIterable {
    case tram, metro, trolleybus, bus, train, ferry

    /// Localized name shown in callouts and the legend.
    var localizedName: String {
        switch self {
        case .tram: return String(localized: "Tramvaj")
        case .metro: return String(localized: "Metro")
        case .trolleybus: return String(localized: "Trolejbus")
        case .bus: return String(localized: "Autobus")
        case .train: return String(localized: "Vlak")
        case .ferry: return String(localized: "Přívoz")
        }
    }

    /// City-aware name. Easter egg: in Brno a tram is a "Šalina" (local hantec
    /// slang) — deliberately kept in every language.
    func displayName(brno: Bool) -> String {
        (self == .tram && brno) ? "Šalina" : localizedName
    }
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
    let destinationId: Int?       // Brno: FinalStopID; resolved to a stop name for the callout
    let destinationName: String?  // Prague: destination text (trip_headsign), used directly
    var delay: Double? = nil      // minutes; Brno stream feed only (not shown in UI yet)

    static func == (a: Vehicle, b: Vehicle) -> Bool {
        a.id == b.id
            && a.coordinate.latitude == b.coordinate.latitude
            && a.coordinate.longitude == b.coordinate.longitude
            && a.bearing == b.bearing
    }
}
