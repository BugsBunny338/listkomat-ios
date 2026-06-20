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

        init(sentAt: Date, validFrom: Date, endDate: Date) {
            self.sentAt = sentAt; self.validFrom = validFrom; self.endDate = endDate
        }

        private enum CodingKeys: String, CodingKey { case sentAt, validFrom, endDate, startDate }

        /// Backward-compatible decode: a 2.0 activity still in flight when the user
        /// updates persisted the old `{startDate, endDate}` shape. Map its
        /// `startDate` → both `sentAt` and `validFrom` so it decodes cleanly (it
        /// simply has no buffer phase, which is correct — it predates this feature).
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            endDate = try c.decode(Date.self, forKey: .endDate)
            if let validFrom = try c.decodeIfPresent(Date.self, forKey: .validFrom) {
                self.validFrom = validFrom
                sentAt = try c.decodeIfPresent(Date.self, forKey: .sentAt) ?? validFrom
            } else {
                let legacy = try c.decode(Date.self, forKey: .startDate)
                sentAt = legacy
                validFrom = legacy
            }
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(sentAt, forKey: .sentAt)
            try c.encode(validFrom, forKey: .validFrom)
            try c.encode(endDate, forKey: .endDate)
        }
    }

    var cityName: String
    var ticketLabel: String   // e.g. "30 min"
    var priceKc: Int
}
