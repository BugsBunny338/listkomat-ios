import ActivityKit
import Foundation

/// Starts / ends the ticket time-left Live Activity and tracks whether one is
/// running so the app can show an "end ticket" control. The countdown starts on
/// the SMS compose `.sent` result — which means "handed off", NOT "delivered"
/// (iOS gives no delivery callback) — so the user must be able to end it
/// manually if the purchase actually failed.
@MainActor
final class LiveActivityController: ObservableObject {
    struct ActiveTicket: Equatable {
        let cityName: String
        let ticketLabel: String
    }

    @Published private(set) var active: ActiveTicket?

    init() {
        syncState()
        observe()
    }

    func start(city: City, ticket: Ticket) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        endAllNow()
        let timeline = TicketTimeline.make(sentAt: Date(),
                                           durationSeconds: Double(ticket.durationMinutes) * 60)
        let attributes = TicketActivityAttributes(
            cityName: city.name,
            ticketLabel: ticket.duration,
            priceKc: ticket.priceKc
        )
        let state = TicketActivityAttributes.ContentState(
            sentAt: timeline.sentAt, validFrom: timeline.validFrom, endDate: timeline.endDate)
        do {
            _ = try Activity.request(attributes: attributes,
                                     content: ActivityContent(state: state, staleDate: timeline.endDate))
            active = ActiveTicket(cityName: city.name, ticketLabel: ticket.duration)
        } catch {
            // Best-effort; nothing to surface if it fails.
        }
    }

    /// User-initiated end (e.g. the send failed, or they're done).
    func stop() {
        endAllNow()
        active = nil
    }

    private func endAllNow() {
        for activity in Activity<TicketActivityAttributes>.activities {
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
        }
    }

    private func syncState() {
        if let activity = Activity<TicketActivityAttributes>.activities.first {
            active = ActiveTicket(cityName: activity.attributes.cityName,
                                  ticketLabel: activity.attributes.ticketLabel)
        } else {
            active = nil
        }
    }

    /// Keep `active` in sync when activities start, end, or expire while the app is open.
    private func observe() {
        Task { [weak self] in
            for await activity in Activity<TicketActivityAttributes>.activityUpdates {
                await MainActor.run { self?.syncState() }
                Task { [weak self] in
                    for await state in activity.activityStateUpdates {
                        if state == .ended || state == .dismissed {
                            await MainActor.run { self?.syncState() }
                        }
                    }
                }
            }
        }
    }
}
