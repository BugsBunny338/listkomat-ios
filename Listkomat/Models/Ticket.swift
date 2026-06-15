import Foundation

/// A single buyable ticket: the SMS keyword to send, plus display info.
struct Ticket: Identifiable, Codable, Hashable {
    let code: String            // SMS body to send, e.g. "DPT42"
    let duration: String        // human label, e.g. "30 min", "24 h"
    let durationMinutes: Int    // for the v1 time-left countdown (M3)
    let priceKc: Int
    let note: String?           // e.g. "zlevněný", "vnitřní zóna"

    var id: String { code }
}
