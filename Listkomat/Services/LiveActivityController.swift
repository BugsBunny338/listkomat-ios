import ActivityKit
import Foundation
import SwiftUI

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
        let validFrom: Date   // banner shows "čeká na potvrzení" + Potvrdit nyní until this
    }

    @Published private(set) var active: ActiveTicket?

    init() {
        syncState()
        observe()
    }

    func start(city: City, ticket: Ticket, accent: Color) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        endAllNow()
        let timeline = TicketTimeline.make(sentAt: Date(),
                                           durationSeconds: Double(ticket.durationMinutes) * 60)
        let attributes = TicketActivityAttributes(
            cityName: city.name,
            ticketLabel: ticket.duration,
            priceKc: ticket.priceKc,
            accentHex: accent.rgbHex
        )
        let state = TicketActivityAttributes.ContentState(
            sentAt: timeline.sentAt, validFrom: timeline.validFrom, endDate: timeline.endDate)
        do {
            // staleDate = validFrom DELIBERATELY repurposes `isStale` as a phase flag:
            // the system re-renders the widget when staleDate passes, which is the only
            // backend-free way to flip pending → valid on a locked screen. The widget
            // gates the pending block on `!context.isStale`. ⚠️ Do NOT "fix" this back
            // to staleDate = endDate — that would break the pending→valid transition.
            _ = try Activity.request(attributes: attributes,
                                     content: ActivityContent(state: state, staleDate: timeline.validFrom))
            active = ActiveTicket(cityName: city.name, ticketLabel: ticket.duration,
                                  validFrom: timeline.validFrom)
        } catch {
            // Best-effort; nothing to surface if it fails.
        }
    }

    /// User got the confirmation SMS early — re-anchor validity to now.
    func confirmNow() {
        guard let activity = Activity<TicketActivityAttributes>.activities.first else { return }
        let now = Date()
        let s = activity.content.state
        let timeline = TicketTimeline(sentAt: s.sentAt, validFrom: s.validFrom, endDate: s.endDate)
            .confirmed(at: now)
        let new = TicketActivityAttributes.ContentState(
            sentAt: timeline.sentAt, validFrom: timeline.validFrom, endDate: timeline.endDate)
        // Flip the in-app banner immediately — don't wait on the async update + state
        // re-read, which lagged a tap behind (the "needs two taps" bug).
        if let a = active {
            active = ActiveTicket(cityName: a.cityName, ticketLabel: a.ticketLabel,
                                  validFrom: timeline.validFrom)
        }
        Task {
            // staleDate = now → widget is immediately stale → flips to the valid layout.
            await activity.update(ActivityContent(state: new, staleDate: now))
            // Reconcile: no-op on success, but if the activity was ended/dismissed out
            // from under us the optimistic `active` is corrected (banner ↔ widget agree).
            syncState()
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
                                  ticketLabel: activity.attributes.ticketLabel,
                                  validFrom: activity.content.state.validFrom)
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
