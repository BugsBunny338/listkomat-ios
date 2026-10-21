import Foundation
import UserNotifications

/// The "Jízdenka vypršela" notification at the ticket's `endDate` (Android:
/// notify/TicketNotifications.kt). A local notification needs no running app,
/// so it lands on time even while the app is suspended — unlike anything the
/// app could do itself at that moment.
///
/// Authorization is asked at the first purchase, the moment the notification
/// first has something to say (Android asks for POST_NOTIFICATIONS at the same
/// point). Declining just means no notification; the banner still flips to
/// its expired state in-app.
final class TicketNotifications: NSObject, UNUserNotificationCenterDelegate {
    static let shared = TicketNotifications()

    static let expiryId = "ticket-expiry"

    private var center: UNUserNotificationCenter { .current() }

    /// Show the expiry notification even while the app is in front — the
    /// banner changes too, but the sound is the part that tells you.
    func install() {
        center.delegate = self
    }

    /// (Re)schedule the expiry for `endDate`, asking for permission first if
    /// it was never asked. Replaces any earlier schedule and clears a delivered
    /// "expired" left over from the previous ticket. `isCurrent` is asked on the
    /// main queue once permission is settled, so a ticket ended meanwhile
    /// doesn't leave its notification behind.
    func scheduleExpiry(at endDate: Date, isCurrent: @escaping @MainActor () -> Bool) {
        cancel()
        guard endDate > Date() else { return }
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            Task { @MainActor in self.add(endDate: endDate, isCurrent: isCurrent) }
        }
    }

    @MainActor
    private func add(endDate: Date, isCurrent: @MainActor () -> Bool) {
        let interval = endDate.timeIntervalSinceNow
        guard isCurrent(), interval > 0 else { return }
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Jízdenka vypršela")
        content.body = String(localized: "Platnost jízdenky skončila.")
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        center.add(UNNotificationRequest(identifier: Self.expiryId, content: content, trigger: trigger))
    }

    func cancel() {
        center.removePendingNotificationRequests(withIdentifiers: [Self.expiryId])
        center.removeDeliveredNotifications(withIdentifiers: [Self.expiryId])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }
}
