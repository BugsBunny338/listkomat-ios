import ActivityKit
import Foundation

/// Shared between the app (which starts the activity) and the widget extension
/// (which renders it). The countdown is driven by start/end dates so the timer
/// ticks on-device with no push updates.
struct TicketActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var sentAt: Date
        var validFrom: Date
        var endDate: Date
    }

    var cityName: String
    var ticketLabel: String   // e.g. "30 min"
    var priceKc: Int
}
