import ActivityKit
import Foundation
import SwiftUI

/// Owns the one active ticket: persists it (`ActiveTicketStore`), schedules its
/// expiry notification, and mirrors it into the time-left Live Activity. The
/// stored ticket is the source of truth — the banner reads `active`, and the
/// Live Activity is best-effort: with Live Activities switched off the ticket
/// still gets its banner, countdown, confirm, end and expiry (Android keeps the
/// ticket in prefs the same way and treats its notification as a mirror).
@MainActor
final class LiveActivityController: ObservableObject {
    @Published private(set) var active: ActiveTicket?

    private let store: ActiveTicketStore
    private let notifications: TicketNotifications

    /// Bumped whenever the user starts or ends a ticket, so work that outlives
    /// an `await` (a Live Activity update, the in-process expiry timer) can tell
    /// that it no longer concerns the ticket on screen (#19).
    private var generation = 0

    /// Ends the Live Activity at `endDate` while the process is alive. A
    /// suspended app can't run it — then the next return to the app does
    /// (`refresh()`), and the expiry notification lands on time regardless.
    private var expiryTask: Task<Void, Never>?

    /// How long the expired Live Activity stays on the lock screen.
    static let expiredActivityLinger: TimeInterval = 15 * 60

    init(store: ActiveTicketStore = ActiveTicketStore(),
         notifications: TicketNotifications = .shared) {
        self.store = store
        self.notifications = notifications
        restore()
    }

    func start(city: City, ticket: Ticket, accent: Color) {
        let timeline = TicketTimeline.make(sentAt: Date(),
                                           durationSeconds: Double(ticket.durationMinutes) * 60)
        let new = ActiveTicket(cityKey: city.key, cityName: city.localizedName,
                               ticketLabel: ticket.localizedDuration, ticketCode: ticket.code,
                               priceKc: ticket.priceKc, accentHex: accent.rgbHex, timeline: timeline)
        generation += 1
        save(new)
        endAllActivitiesNow()
        requestActivity(for: new)
        scheduleExpiry(for: new)
    }

    /// User got the confirmation SMS early — re-anchor validity to now. Only
    /// while pending: a late tap must not extend a ticket that is already valid.
    func confirmNow() {
        guard let current = active else { return }
        let now = Date()
        guard current.timeline.isPending(at: now) else { return }
        var confirmed = current
        confirmed.timeline = current.timeline.confirmed(at: now)
        // The banner flips at once: it reads the stored ticket, never the
        // activity's content (whose read-back lags an update — the #19 bug).
        save(confirmed)
        scheduleExpiry(for: confirmed)
        guard let activity = liveActivity else { return }
        let generationAtTap = generation
        Task {
            // staleDate = now → widget is immediately stale → flips to the valid layout.
            await activity.update(ActivityContent(state: Self.state(confirmed.timeline), staleDate: now))
            // Ended (or replaced) while the update was in flight: don't leave the
            // activity we just updated running for a ticket that is gone.
            if generationAtTap != generation {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    /// User-initiated end (the send failed, they're done, or dismissing the
    /// expired banner).
    func stop() {
        generation += 1
        expiryTask?.cancel()
        store.clear()
        active = nil
        notifications.cancel()
        endAllActivitiesNow()
    }

    /// The app came back to the foreground: drop a ticket that expired long
    /// ago, end the Live Activity of one that expired while we were suspended,
    /// and re-arm the in-process expiry timer (it doesn't run while suspended).
    func refresh(now: Date = Date()) {
        guard let current = active else { return }
        guard ActiveTicket.restored(current, now: now) != nil else { return stop() }
        armExpiryTimer(for: current, now: now)
    }

    // MARK: - Persistence

    private func save(_ ticket: ActiveTicket) {
        store.save(ticket)
        active = ticket
    }

    /// Launch: load the stored ticket. A 2.5 build kept the ticket only in its
    /// Live Activity, so on the first 2.6 launch a running activity is adopted.
    private func restore() {
        let stored = store.load() ?? liveActivity.map(Self.adopted)
        guard let ticket = ActiveTicket.restored(stored, now: Date()) else {
            store.clear()
            endAllActivitiesNow()
            return
        }
        save(ticket)
        armExpiryTimer(for: ticket, now: Date())
    }

    private static func adopted(_ activity: Activity<TicketActivityAttributes>) -> ActiveTicket {
        let s = activity.content.state
        return ActiveTicket(cityKey: nil, cityName: activity.attributes.cityName,
                            ticketLabel: activity.attributes.ticketLabel, ticketCode: nil,
                            priceKc: activity.attributes.priceKc,
                            accentHex: activity.attributes.accentHex,
                            timeline: TicketTimeline(sentAt: s.sentAt, validFrom: s.validFrom, endDate: s.endDate))
    }

    // MARK: - Expiry

    private func scheduleExpiry(for ticket: ActiveTicket) {
        let endDate = ticket.timeline.endDate
        notifications.scheduleExpiry(at: endDate) { [weak self] in
            self?.active?.timeline.endDate == endDate
        }
        armExpiryTimer(for: ticket, now: Date())
    }

    private func armExpiryTimer(for ticket: ActiveTicket, now: Date) {
        expiryTask?.cancel()
        let generationAtArm = generation
        let wait = ticket.timeline.endDate.timeIntervalSince(now)
        expiryTask = Task { [weak self] in
            if wait > 0 {
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            }
            guard !Task.isCancelled, let self, self.generation == generationAtArm,
                  let current = self.active else { return }
            self.endActivities(expired: current)
        }
    }

    /// End the Live Activity at expiry with content that says so, left on the
    /// lock screen for `expiredActivityLinger` after `endDate` (at once if that
    /// has passed too). The Dynamic Island clears as soon as it ends.
    private func endActivities(expired ticket: ActiveTicket) {
        var state = Self.state(ticket.timeline)
        state.expired = true
        let content = ActivityContent(state: state, staleDate: nil)
        let dismissAt = ticket.timeline.endDate.addingTimeInterval(Self.expiredActivityLinger)
        for activity in Activity<TicketActivityAttributes>.activities where Self.isLive(activity.activityState) {
            Task { await activity.end(content, dismissalPolicy: .after(dismissAt)) }
        }
    }

    // MARK: - Live Activity (best-effort mirror)

    private func requestActivity(for ticket: ActiveTicket) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let attributes = TicketActivityAttributes(
            cityName: ticket.cityName,
            ticketLabel: ticket.ticketLabel,
            priceKc: ticket.priceKc,
            accentHex: ticket.accentHex
        )
        // staleDate = validFrom DELIBERATELY repurposes `isStale` as a phase flag:
        // the system re-renders the widget when staleDate passes, which is the only
        // backend-free way to flip pending → valid on a locked screen. The widget
        // gates the pending block on `!context.isStale`. ⚠️ Do NOT "fix" this back
        // to staleDate = endDate — that would break the pending→valid transition.
        // Best-effort; nothing to surface if it fails — the banner carries the ticket.
        _ = try? Activity.request(
            attributes: attributes,
            content: ActivityContent(state: Self.state(ticket.timeline), staleDate: ticket.timeline.validFrom))
    }

    private static func state(_ timeline: TicketTimeline) -> TicketActivityAttributes.ContentState {
        TicketActivityAttributes.ContentState(
            sentAt: timeline.sentAt, validFrom: timeline.validFrom, endDate: timeline.endDate)
    }

    private func endAllActivitiesNow() {
        for activity in Activity<TicketActivityAttributes>.activities {
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
        }
    }

    /// Is this activity still running (so it can be updated or ended)?
    ///
    /// ⚠️ Deliberately `!= .ended && != .dismissed` rather than `== .active`. This app
    /// repurposes `staleDate` as a phase flag (see `requestActivity`), and `confirmNow()`
    /// sets it to *now* — so a confirmed ticket's activity is `.stale`, not `.active`.
    /// Measured on the simulator: after `start()` → `.active`; after `confirmNow()` →
    /// `.stale`; after `end(dismissalPolicy: .default)` → `.ended`, and the activity is
    /// *still returned by* `Activity.activities`.
    nonisolated static func isLive(_ state: ActivityState) -> Bool {
        state != .ended && state != .dismissed
    }

    /// The running activity, if any. `Activity.activities` keeps an activity
    /// after it ends until it is dismissed, so it must be filtered.
    private var liveActivity: Activity<TicketActivityAttributes>? {
        Activity<TicketActivityAttributes>.activities.first { Self.isLive($0.activityState) }
    }
}
