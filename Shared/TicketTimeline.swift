import Foundation

/// All ticket-validity date math, ActivityKit-free so it's unit-testable.
/// The ticket isn't valid until the operator's confirmation SMS (~2 min after
/// send, unreadable by apps), so validity is anchored to `validFrom`, not send.
struct TicketTimeline: Codable, Hashable {
    var sentAt: Date
    var validFrom: Date
    var endDate: Date

    /// Length of the valid window (invariant: endDate − validFrom).
    var duration: TimeInterval { endDate.timeIntervalSince(validFrom) }

    /// Before this, the ticket shows as "čeká na potvrzení", not counting down.
    func isPending(at now: Date) -> Bool { now < validFrom }

    func isExpired(at now: Date) -> Bool { now >= endDate }

    /// Pending (awaiting the confirmation SMS) → valid → expired.
    enum Phase { case pending, valid, expired }

    func phase(at now: Date) -> Phase {
        if isExpired(at: now) { return .expired }
        return isPending(at: now) ? .pending : .valid
    }

    /// Estimated gap between SMS send and the confirmation SMS.
    static let buffer: TimeInterval = 120

    static func make(sentAt: Date,
                     durationSeconds: TimeInterval,
                     buffer: TimeInterval = buffer) -> TicketTimeline {
        let validFrom = sentAt.addingTimeInterval(buffer)
        return TicketTimeline(sentAt: sentAt,
                              validFrom: validFrom,
                              endDate: validFrom.addingTimeInterval(durationSeconds))
    }

    /// Re-anchor to now (confirmation arrived), keeping the same duration.
    func confirmed(at now: Date) -> TicketTimeline {
        TicketTimeline(sentAt: sentAt, validFrom: now, endDate: now.addingTimeInterval(duration))
    }
}
