import Foundation

/// The one ticket currently counting down, persisted so it survives the app
/// being killed (the validity window outlives the app by design). This, not the
/// Live Activity, is the source of truth: the banner, the expiry notification
/// and the Live Activity all follow it, and the Live Activity is only a
/// best-effort mirror (the user can switch Live Activities off).
///
/// The countdown starts on the SMS compose `.sent` result — "handed off", NOT
/// "delivered" (iOS gives no delivery callback) — so the user must be able to
/// end it manually if the purchase actually failed.
struct ActiveTicket: Codable, Equatable {
    /// nil only for a ticket adopted from a 2.5 Live Activity, which carried no key.
    var cityKey: String?
    /// Localized at purchase; the banner re-resolves it from `cityKey` when it can.
    var cityName: String
    var ticketLabel: String
    /// The SMS body that bought it. nil for an adopted 2.5 ticket.
    var ticketCode: String?
    var priceKc: Int
    /// Theme accent at purchase, carried into the Live Activity.
    var accentHex: UInt32?
    var timeline: TicketTimeline

    /// How long an expired ticket stays on screen (in its expired state) after
    /// `endDate`; older ones are dropped at launch (Android: EXPIRED_KEEP_MS).
    static let expiredKeep: TimeInterval = 60 * 60

    /// What a relaunch keeps: the stored ticket, unless it expired more than
    /// `expiredKeep` ago. A freshly expired one stays, so its expired state is
    /// seen rather than the banner silently vanishing.
    static func restored(_ stored: ActiveTicket?, now: Date) -> ActiveTicket? {
        guard let stored, now < stored.timeline.endDate.addingTimeInterval(expiredKeep) else { return nil }
        return stored
    }
}
