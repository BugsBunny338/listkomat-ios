import Foundation

/// Persists the single active ticket in UserDefaults (Android: ActiveTicketStore
/// in SharedPreferences), so the banner, the expiry notification and a relaunch
/// don't depend on ActivityKit.
struct ActiveTicketStore {
    static let key = "activeTicket"

    var defaults: UserDefaults = .standard

    func load() -> ActiveTicket? {
        guard let data = defaults.data(forKey: Self.key) else { return nil }
        return try? JSONDecoder().decode(ActiveTicket.self, from: data)
    }

    func save(_ ticket: ActiveTicket) {
        guard let data = try? JSONEncoder().encode(ticket) else { return }
        defaults.set(data, forKey: Self.key)
    }

    func clear() {
        defaults.removeObject(forKey: Self.key)
    }
}
