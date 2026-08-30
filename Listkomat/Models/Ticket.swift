import Foundation

/// A single buyable ticket: the SMS keyword to send, plus display info.
struct Ticket: Identifiable, Codable, Hashable {
    let code: String            // SMS body to send, e.g. "DPT42"
    /// Legacy Czech display label ("30 min", "24 h"). Still decoded because the
    /// catalog keeps it for builds shipped before durations were formatted
    /// client-side, but the UI now uses `localizedDuration`.
    let duration: String
    let durationMinutes: Int    // drives the countdown *and* the displayed duration
    let priceKc: Int
    let note: String?           // Czech source text, e.g. "zlevněný", "vnitřní zóna"
    /// Optional per-language overrides for `note`; absent decodes to nil.
    var i18n: [String: CatalogText]? = nil

    var id: String { code }
}
