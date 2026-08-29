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
            // Reconcile existence only — see `reconciled(local:snapshot:)`. Reading the
            // updated content back here is NOT safe: it lags the update we just made.
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

    /// ActivityKit's snapshot is authoritative for whether an activity *exists*; this
    /// controller's own writes are authoritative for its *content*.
    ///
    /// `activity.content.state` does not reflect an update the instant
    /// `await activity.update(...)` returns — measured on the simulator, the read-back
    /// still carried the pre-update `validFrom`. Reconciling content against that
    /// snapshot pushed a just-confirmed ticket back to "čeká na potvrzovací SMS" and
    /// cost the user a second tap (#19). Nothing but this controller ever changes an
    /// activity's content (there is no push backend), so keeping the local value is
    /// safe — while an activity that has ended or been dismissed still clears the banner.
    static func reconciled(local: ActiveTicket?, snapshot: ActiveTicket?) -> ActiveTicket? {
        guard snapshot != nil else { return nil }   // ended/dismissed → banner goes away
        return local ?? snapshot                    // fresh launch adopts what's running
    }

    private func syncState() {
        let snapshot = Activity<TicketActivityAttributes>.activities.first.map {
            ActiveTicket(cityName: $0.attributes.cityName,
                         ticketLabel: $0.attributes.ticketLabel,
                         validFrom: $0.content.state.validFrom)
        }
        active = Self.reconciled(local: active, snapshot: snapshot)
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
