import ActivityKit
import Foundation

/// Starts/stops the ticket time-left Live Activity (iOS 16.2+ ActivityKit API).
enum TicketActivityController {
    static func start(city: City, ticket: Ticket) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        // Avoid stacking: end any existing ticket activities first.
        for activity in Activity<TicketActivityAttributes>.activities {
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
        }

        let start = Date()
        let end = start.addingTimeInterval(Double(ticket.durationMinutes) * 60)
        let attributes = TicketActivityAttributes(
            cityName: city.name,
            ticketLabel: ticket.duration,
            priceKc: ticket.priceKc
        )
        let state = TicketActivityAttributes.ContentState(startDate: start, endDate: end)

        do {
            _ = try Activity.request(
                attributes: attributes,
                content: ActivityContent(state: state, staleDate: end)
            )
        } catch {
            // Best-effort; nothing to surface to the user if it fails.
        }
    }
}
