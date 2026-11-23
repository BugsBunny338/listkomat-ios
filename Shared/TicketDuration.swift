import Foundation

/// A ticket's validity as words ("30 minut" / "30 minutes"), formatted from its
/// minutes whenever it is shown, never stored: a label formatted at purchase
/// stays in that language (iOS P1 2d, Android #31). In Shared so the Live
/// Activity formats it in the same language as the sentence around it.
enum TicketDuration {
    /// Whole hours read better than three-digit minutes, but only past the point
    /// where operators stop selling in minutes: a 60-minute ticket is sold as
    /// sixty minutes, a 1440-minute one as a day pass.
    enum Unit: Hashable {
        case minutes(Int)
        case hours(Int)
    }

    static func unit(minutes: Int) -> Unit {
        if minutes >= 120, minutes % 60 == 0 { return .hours(minutes / 60) }
        return .minutes(minutes)
    }

    /// Always rendered right after "Lístek na …" / "Ticket for …" (or after the
    /// city in the banner), so the Czech forms are accusative ("na 1 hodinu",
    /// not "na 1 hodina") — hand-written plural variations rather than
    /// `DateComponentsFormatter`, whose nominative output would be wrong there.
    /// `bundle` and `locale` are for tests that pin a language.
    static func label(minutes: Int, bundle: Bundle = .main, locale: Locale = .current) -> String {
        switch unit(minutes: minutes) {
        case .minutes(let count): return String(localized: "\(count) minut", bundle: bundle, locale: locale)
        case .hours(let count):   return String(localized: "\(count) hodin", bundle: bundle, locale: locale)
        }
    }
}
