import SwiftUI
import CoreLocation

/// Kind of transit vehicle, for tinting the map marker.
enum VehicleKind: String, CaseIterable {
    case tram, metro, trolleybus, bus, train

    /// Czech name shown in callouts and the legend.
    var czechName: String {
        switch self {
        case .tram: return "Tramvaj"
        case .metro: return "Metro"
        case .trolleybus: return "Trolejbus"
        case .bus: return "Autobus"
        case .train: return "Vlak"
        }
    }

    /// City-aware name. Easter egg: in Brno a tram is a "Šalina" (local hantec slang).
    func displayName(brno: Bool) -> String {
        (self == .tram && brno) ? "Šalina" : czechName
    }

    /// Marker color — distinct, refined transit palette.
    var color: Color {
        switch self {
        case .tram: return Color(hex: 0xD7263D)        // crimson
        case .metro: return Color(hex: 0xE0812B)       // amber (Prague only)
        case .trolleybus: return Color(hex: 0x2A9D8F)  // teal-green
        case .bus: return Color(hex: 0x2E6F95)         // steel blue
        case .train: return Color(hex: 0x6A4C93)       // purple
        }
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
