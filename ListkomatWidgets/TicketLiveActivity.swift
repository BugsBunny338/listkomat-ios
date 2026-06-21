import ActivityKit
import SwiftUI
import WidgetKit

/// The ticket time-left Live Activity: lock screen / banner + Dynamic Island.
/// The countdown uses Text(timerInterval:) so it ticks on-device, no pushes.
///
/// Pending vs valid is gated on `context.isStale`: `start()` sets the activity's
/// staleDate = validFrom, so the system re-renders (flipping pending → valid) when
/// it passes — and `confirmNow()` updates with a past staleDate to flip instantly.
/// No push needed.
struct TicketLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TicketActivityAttributes.self) { context in
            LockScreenView(context: context)
                .padding(16)
                .activityBackgroundTint(accent(context).opacity(0.12))
                .activitySystemActionForegroundColor(accent(context))
        } dynamicIsland: { context in
            let tint = accent(context)
            let pending = !context.isStale
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.attributes.cityName, systemImage: "tram.fill")
                        .font(.headline)
                        .foregroundStyle(tint)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(timerInterval: context.state.validFrom...context.state.endDate, countsDown: true)
                        .monospacedDigit()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                        .foregroundStyle(tint)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 2) {
                        Text("Lístek na \(context.attributes.ticketLabel) · \(context.attributes.priceKc) Kč")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if pending {
                            (Text("čeká na potvrzovací SMS · platí za ")
                                + Text(timerInterval: context.state.sentAt...context.state.validFrom, countsDown: true))
                                .font(.caption2)
                                .monospacedDigit()
                                .foregroundStyle(.orange)
                        }
                    }
                }
            } compactLeading: {
                Image(systemName: "tram.fill")
                    .foregroundStyle(tint)
            } compactTrailing: {
                Text(timerInterval: context.state.validFrom...context.state.endDate, countsDown: true)
                    .monospacedDigit()
                    .frame(width: 46)
                    .foregroundStyle(tint)
            } minimal: {
                Image(systemName: "tram.fill")
                    .foregroundStyle(tint)
            }
        }
    }
}

/// Theme accent carried in the attributes; falls back to teal for legacy activities.
private func accent(_ context: ActivityViewContext<TicketActivityAttributes>) -> Color {
    context.attributes.accentHex.map(Color.init(hex:)) ?? .brandTeal
}

private struct LockScreenView: View {
    let context: ActivityViewContext<TicketActivityAttributes>

    private var tint: Color { accent(context) }
    private var pending: Bool { !context.isStale }   // valid once the activity goes stale at validFrom

    var body: some View {
        // City name + the big countdown use the default (primary) colour so they
        // stay legible on the dimmed Always-On display; the accent tints the icon.
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "tram.fill")
                .font(.title3)
                .foregroundStyle(tint)

            VStack(alignment: .leading, spacing: 2) {
                Text(context.attributes.cityName)
                    .font(.headline)
                Text("Lístek na \(context.attributes.ticketLabel) · \(context.attributes.priceKc) Kč")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if pending {
                    // Validity begins at the operator's confirmation SMS; hidden once valid.
                    Text("čeká na potvrzovací SMS")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 1) {
                if pending {
                    // Buffer countdown to validity — self-ticks; gone once valid.
                    (Text("platí za ")
                        + Text(timerInterval: context.state.sentAt...context.state.validFrom, countsDown: true))
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Text("zbývá")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(timerInterval: context.state.validFrom...context.state.endDate, countsDown: true)
                    .font(.title2.weight(.semibold))
                    .monospacedDigit()
                    .multilineTextAlignment(.trailing)
                    .frame(minWidth: 74, alignment: .trailing)
            }
        }
    }
}
