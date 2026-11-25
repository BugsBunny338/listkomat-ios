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
            let pending = !context.isStale && !context.state.expired
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
                        Text("Lístek na \(context.attributes.durationLabel) · \(context.attributes.priceKc) Kč")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if pending {
                            // Single format key so translators control where the
                            // countdown sits in the sentence.
                            Text("čeká na potvrzovací SMS · platí za \(Text(timerInterval: context.state.sentAt...context.state.validFrom, countsDown: true))")
                                .font(.caption2)
                                .monospacedDigit()
                                // The island is always black: the dark shade.
                                .foregroundStyle(LiveActivityText.pendingCaption(
                                    accentHex: accentHex(context), dark: true))
                        }
                    }
                }
            } compactLeading: {
                Image(systemName: "tram.fill")
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)   // decorative; the timer beside it is the content
            } compactTrailing: {
                Text(timerInterval: context.state.validFrom...context.state.endDate, countsDown: true)
                    .monospacedDigit()
                    .frame(width: 46)
                    .foregroundStyle(tint)
            } minimal: {
                // The icon is all there is here: read the city, not "Train".
                Image(systemName: "tram.fill")
                    .foregroundStyle(tint)
                    .accessibilityLabel(Text(verbatim: context.attributes.cityName))
            }
        }
    }
}

/// Theme accent carried in the attributes; falls back to teal for legacy activities.
private func accent(_ context: ActivityViewContext<TicketActivityAttributes>) -> Color {
    Color(hex: accentHex(context))
}

/// The accent as hex (brand teal #56C4CF for legacy activities without one).
private func accentHex(_ context: ActivityViewContext<TicketActivityAttributes>) -> UInt32 {
    context.attributes.accentHex ?? 0x56C4CF
}

private struct LockScreenView: View {
    let context: ActivityViewContext<TicketActivityAttributes>

    private var tint: Color { accent(context) }
    /// The final content the app ends the activity with at expiry.
    private var expired: Bool { context.state.expired }
    /// Valid once the activity goes stale at validFrom. The expired content has
    /// no staleDate, so it must not read as pending.
    private var pending: Bool { !context.isStale && !expired }

    var body: some View {
        // City name + the big countdown use the default (primary) colour so they
        // stay legible on the dimmed Always-On display; the accent tints the icon.
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "tram.fill")
                .font(.title3)
                .foregroundStyle(tint)
                .accessibilityHidden(true)   // decorative: VoiceOver read it as "Train"

            VStack(alignment: .leading, spacing: 2) {
                Text(context.attributes.cityName)
                    .font(.headline)
                Text("Lístek na \(context.attributes.durationLabel) · \(context.attributes.priceKc) Kč")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if pending {
                    // Validity begins at the operator's confirmation SMS; hidden once valid.
                    // Plain .orange measured ~1.7:1 on the light lock screen.
                    DarkBackdropReader { dark in
                        Text("čeká na potvrzovací SMS")
                            .font(.caption2)
                            .foregroundStyle(LiveActivityText.pendingCaption(
                                accentHex: accentHex(context), dark: dark))
                    }
                }
            }

            Spacer(minLength: 8)

            if expired {
                Text("Jízdenka vypršela")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            } else {
                countdown
            }
        }
    }

    private var countdown: some View {
        VStack(alignment: .trailing, spacing: 1) {
            if pending {
                // Buffer countdown to validity — self-ticks; gone once valid.
                // Single format key so translators control the word order.
                Text("platí za \(Text(timerInterval: context.state.sentAt...context.state.validFrom, countsDown: true))")
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

/// Whether the activity sits on a dark backdrop, whatever the system appearance:
/// dark mode, Always-On (luminance reduced; the scheme stays light there) or
/// StandBy (fullscreen, iOS 17+). A light-mode shade on those reads ~3:1.
private struct DarkBackdropReader<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isLuminanceReduced) private var dimmed
    @ViewBuilder let content: (Bool) -> Content

    var body: some View {
        let dark = colorScheme == .dark || dimmed
        if #available(iOS 17.0, *) {
            FullscreenAware(dark: dark, content: content)
        } else {
            content(dark)
        }
    }
}

@available(iOS 17.0, *)
private struct FullscreenAware<Content: View>: View {
    @Environment(\.isActivityFullscreen) private var fullscreen
    let dark: Bool
    let content: (Bool) -> Content

    var body: some View { content(dark || fullscreen) }
}
