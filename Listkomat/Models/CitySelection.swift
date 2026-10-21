import Foundation

/// What GPS knows about where the user is (Android: model/CitySelection.kt).
enum LocationState: Equatable {
    case idle
    case searching
    case denied
    case located(cityKey: String, distanceKm: Double)
}

/// Which city the home screen shows (decided 2026-09-23, revised 2026-10-20;
/// Android shipped it in android#26 and is the spec): GPS wins whenever it
/// delivers. A manual pick overrides it for the session only, and is persisted
/// solely as the fallback for when GPS can't deliver (denied, no fix, nearest
/// city farther than `LocationManager.maxDefaultDistanceKm`). Coming back to the
/// app is a fresh context, except within `manualGrace` of leaving it (or of the
/// pick), so answering a text or sending the ticket SMS doesn't flip the city.
///
/// So the list doesn't swap under the user's thumb, the fallback waits up to
/// `firstFixHold` for this process's first fix; the searching state shows
/// meanwhile. Pure for unit tests.
enum CitySelection {
    static let manualGrace: TimeInterval = 5 * 60
    static let firstFixHold: TimeInterval = 2
    /// Taps on a city's rows count only this long after it appeared.
    static let tapGuard: TimeInterval = 0.6
    /// A cached fix this recent counts as GPS delivering (Android's
    /// LAST_KNOWN_MAX_AGE_MS); moving to another city takes longer than this.
    static let fixMaxAge: TimeInterval = 15 * 60

    static func fixIsFresh(age: TimeInterval) -> Bool { age >= 0 && age <= fixMaxAge }

    static func cityKey(manual: String?, location: LocationState, fallback: String?,
                        awaitingFirstFix: Bool = false) -> String? {
        manual ?? gpsCityKey(location) ?? (awaitingFirstFix ? nil : fallback)
    }

    /// The GPS city, if it's close enough to plausibly be where the user is.
    static func gpsCityKey(_ location: LocationState) -> String? {
        guard case let .located(key, km) = location, km <= maxDefaultDistanceKm else { return nil }
        return key
    }

    /// The manual override after the app comes to the foreground: the last pick
    /// (`fallback`) if it was still on screen less than `manualGrace` ago
    /// (`lastSeenAt` = the pick, or leaving the app while it overrode GPS),
    /// else none.
    static func overrideAfterStart(fallback: String?, lastSeenAt: Date?, now: Date) -> String? {
        guard let lastSeenAt else { return nil }
        let age = now.timeIntervalSince(lastSeenAt)
        return age >= 0 && age < manualGrace ? fallback : nil
    }

    /// Anywhere in CZ is within ~100 km of a supported city; abroad is obviously not.
    static let maxDefaultDistanceKm = 100.0
}
