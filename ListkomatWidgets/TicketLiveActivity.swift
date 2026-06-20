import ActivityKit
import SwiftUI
import WidgetKit

/// The ticket time-left Live Activity: lock screen / banner + Dynamic Island.
/// The countdown uses Text(timerInterval:) so it ticks on-device, no pushes.
struct TicketLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TicketActivityAttributes.self) { context in
            LockScreenView(context: context)
                .padding(16)
                .activityBackgroundTint(Color.brandTeal.opacity(0.12))
                .activitySystemActionForegroundColor(Color.brandTeal)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.attributes.cityName, systemImage: "tram.fill")
                        .font(.headline)
                        .foregroundStyle(Color.brandTeal)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(timerInterval: context.state.validFrom...context.state.endDate, countsDown: true)
                        .monospacedDigit()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                        .foregroundStyle(Color.brandTeal)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text("Lístek na \(context.attributes.ticketLabel) · \(context.attributes.priceKc) Kč")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } compactLeading: {
                Image(systemName: "tram.fill")
                    .foregroundStyle(Color.brandTeal)
            } compactTrailing: {
                Text(timerInterval: context.state.validFrom...context.state.endDate, countsDown: true)
                    .monospacedDigit()
                    .frame(width: 46)
                    .foregroundStyle(Color.brandTeal)
            } minimal: {
                Image(systemName: "tram.fill")
                    .foregroundStyle(Color.brandTeal)
            }
        }
    }
}

private struct LockScreenView: View {
    let context: ActivityViewContext<TicketActivityAttributes>

    var body: some View {
        // City name + countdown use the default (primary) colour so they stay
        // legible on the dimmed Always-On display; teal is only the icon accent.
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "tram.fill")
                .font(.title3)
                .foregroundStyle(Color.brandTeal)

            VStack(alignment: .leading, spacing: 2) {
                Text(context.attributes.cityName)
                    .font(.headline)
                Text("Lístek na \(context.attributes.ticketLabel) · \(context.attributes.priceKc) Kč")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 1) {
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
