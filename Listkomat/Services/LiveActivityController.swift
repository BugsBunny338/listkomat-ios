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

        /// Pending until the confirmation SMS lands. Callers must pass the *wall
        /// clock*: the banner's TimelineView hands out the current schedule entry,
        /// which lags real time by up to a tick (see ContentView).
        func isPending(at now: Date) -> Bool { now < validFrom }
    }

    @Published private(set) var active: ActiveTicket?

    /// Bumped whenever the user starts or ends a ticket, so an in-flight
    /// `confirmNow()` can tell that its reconcile no longer concerns the ticket
    /// on screen (e.g. the user hit "Ukončit" while the update was in flight).
    private var generation = 0

    init() {
        syncState()
        // An activity can outlive the process (relaunch with a ticket still running).
        if let running = liveActivity { observeLifecycle(of: running) }
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
            let activity = try Activity.request(
                attributes: attributes,
                content: ActivityContent(state: state, staleDate: timeline.validFrom))
            active = ActiveTicket(cityName: city.name, ticketLabel: ticket.duration,
                                  validFrom: timeline.validFrom)
            generation += 1
            observeLifecycle(of: activity)
        } catch {
            // Best-effort; nothing to surface if it fails.
        }
    }

    /// User got the confirmation SMS early — re-anchor validity to now.
    func confirmNow() {
        guard let activity = liveActivity else { return }
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
        let generationAtTap = generation
        Task {
            // staleDate = now → widget is immediately stale → flips to the valid layout.
            await activity.update(ActivityContent(state: new, staleDate: now))
            // If the user ended (or replaced) the ticket while the update was in
            // flight, this reconcile is about a ticket that is no longer on screen —
            // running it would resurrect the banner from a snapshot we already know
            // is stale. Bail instead.
            guard generationAtTap == generation else { return }
            // Reconcile existence only — see `reconciled(local:snapshot:)`. Reading the
            // updated content back here is NOT safe: it lags the update we just made.
            syncState()
        }
    }

    /// User-initiated end (e.g. the send failed, or they're done).
    func stop() {
        endAllNow()
        active = nil
        generation += 1
    }

    private func endAllNow() {
        for activity in Activity<TicketActivityAttributes>.activities {
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
        }
    }

    /// Is this activity still one the banner should represent?
    ///
    /// ⚠️ Deliberately `!= .ended && != .dismissed` rather than `== .active`. This app
    /// repurposes `staleDate` as a phase flag (see `start()`), and `confirmNow()` sets
    /// it to *now* — so a confirmed ticket's activity is `.stale`, not `.active`.
    /// Filtering on `.active` would blank the banner the moment the user confirms.
    /// Measured on the simulator: after `start()` → `.active`; after `confirmNow()` →
    /// `.stale`; after `end(dismissalPolicy: .default)` → `.ended`, and the activity is
    /// *still returned by* `Activity.activities` (which is why existence alone is not
    /// enough to decide the banner should stay).
    static func isLive(_ state: ActivityState) -> Bool {
        state != .ended && state != .dismissed
    }

    /// The activity the banner represents, if any. `Activity.activities` keeps an
    /// activity after it ends until it is dismissed, so it must be filtered.
    private var liveActivity: Activity<TicketActivityAttributes>? {
        Activity<TicketActivityAttributes>.activities.first { Self.isLive($0.activityState) }
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
    /// safe — while an activity that has ended or been dismissed still clears the banner
    /// (the caller filters those out of the snapshot; see `isLive`).
    static func reconciled(local: ActiveTicket?, snapshot: ActiveTicket?) -> ActiveTicket? {
        guard snapshot != nil else { return nil }   // ended/dismissed → banner goes away
        return local ?? snapshot                    // fresh launch adopts what's running
    }

    private func syncState() {
        let snapshot = liveActivity.map {
            ActiveTicket(cityName: $0.attributes.cityName,
                         ticketLabel: $0.attributes.ticketLabel,
                         validFrom: $0.content.state.validFrom)
        }
        active = Self.reconciled(local: active, snapshot: snapshot)
    }

    /// Clear the banner when an activity ends or is dismissed out from under us.
    ///
    /// ⚠️ This deliberately subscribes to the activity we hold, rather than going
    /// through `Activity.activityUpdates`. That sequence is documented as reporting
    /// newly started activities, but measured here it never yielded for an activity
    /// this same process had just requested — so the nested `activityStateUpdates`
    /// loop it was supposed to spawn never started, and the banner outlived its
    /// activity indefinitely. Subscribing directly is the observation that actually
    /// fires. Do not "restore" the `activityUpdates` version.
    private func observeLifecycle(of activity: Activity<TicketActivityAttributes>) {
        Task { [weak self] in
            for await state in activity.activityStateUpdates {
                guard state == .ended || state == .dismissed else { continue }
                await MainActor.run { self?.syncState() }
            }
        }
    }
}
