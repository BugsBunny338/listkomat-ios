import SwiftUI
import MessageUI
import StoreKit

/// The list of tickets for the current city, headed by the city's landmark icon
/// (teal, no tile). Tapping a ticket opens a pre-filled SMS to that city's number.
struct TicketListView: View {
    let city: City
    let updatedAt: String
    let isOffline: Bool
    let liveActivity: LiveActivityController
    let accent: Color

    @State private var pending: Ticket?
    @State private var cannotSend = false
    @State private var sendFailed = false
    @State private var showingSimInfo = false
    /// nil until StoreKit answers; ForeignSimNotice treats that as "unknown", not "foreign".
    @State private var storefrontCountry: String?

    /// The one-time note is dismissed for good once tapped away (issue #15).
    @AppStorage("foreignSimNoticeDismissed") private var foreignSimNoticeDismissed = false

    private var showsForeignSimNotice: Bool {
        ForeignSimNotice.shouldShow(
            uiLanguage: Bundle.main.preferredLocalizations.first,
            storefrontCountry: storefrontCountry,
            dismissed: foreignSimNoticeDismissed
        )
    }

    private var formattedDate: String {
        let parts = updatedAt.split(separator: "-")
        guard parts.count == 3, let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]) else {
            return updatedAt
        }
        return "\(d). \(m). \(y)"
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if city.showsLiveMap {
                NavigationLink {
                    LiveMapView(city: city)
                } label: {
                    Label("Živá mapa", systemImage: "map")
                        .font(.brandBold(15, relativeTo: .subheadline))
                }
                .buttonStyle(.bordered)
                .tint(accent)
                .padding(.bottom, 12)
                // Eager connect (#12): Brno's stream accumulates vehicles only
                // as each one reports, so start it while the user is still on
                // the ticket list and the map opens already populated. The task
                // is cancelled when the screen leaves, releasing the socket
                // after the grace period.
                .task(id: city.key) { await LiveSources.keepWarm(cityKey: city.key) }
            }
            if showsForeignSimNotice { foreignSimNotice }
            List {
                Section {
                    ForEach(city.tickets) { ticket in
                        Button { tap(ticket) } label: { row(ticket) }
                            .buttonStyle(.plain)
                    }
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Po klepnutí se otevře předvyplněná SMS na číslo \(city.smsNumber). Lístek koupíte jejím odesláním.")
                        // Permanent entry point to the full explanation — the
                        // one-time note above can be dismissed, this can't.
                        Button { showingSimInfo = true } label: {
                            HStack(spacing: 4) {
                                Text("Funguje s českou SIM kartou.")
                                Text("Více").underline()
                            }
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(accent)
                        if isOffline {
                            Label("Offline – zobrazen uložený ceník (k \(formattedDate))", systemImage: "wifi.slash")
                                .foregroundStyle(.orange)
                        } else {
                            Text("Ceník platný k \(formattedDate)")
                        }
                    }
                }
            }
        }
        .background(Color(.systemGroupedBackground))
        // Storefront is the second half of the "probably foreign" heuristic. It
        // needs no IAP setup or permission, and it only ever adds a note.
        .task {
            storefrontCountry = await Storefront.current?.countryCode
        }
        .sheet(item: $pending) { ticket in
            MessageComposeView(recipient: city.smsNumber, body: ticket.code) { result in
                pending = nil
                if case .sent = result {
                    liveActivity.start(city: city, ticket: ticket, accent: accent)
                }
                // A failed send is the one doomed purchase we *can* see — a
                // silent failure here is what earns 1★ reviews (issue #15).
                if case .failed = result {
                    sendFailed = true
                }
                #if targetEnvironment(simulator)
                // The simulator can't actually send SMS, so start the Live
                // Activity regardless — lets us demo the time-left countdown.
                liveActivity.start(city: city, ticket: ticket, accent: accent)
                #endif
            }
        }
        .alert("SMS nelze odeslat", isPresented: $cannotSend) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Toto zařízení neumí posílat SMS (např. iPad bez SIM).")
        }
        .alert("SMS se nepodařilo odeslat", isPresented: $sendFailed) {
            Button("Více informací") { showingSimInfo = true }
            Button("OK", role: .cancel) {}
        } message: {
            Text("Lístek se nekoupil, nic se nestrhlo. Prémiové SMS fungují jen ze SIM karty českého operátora — ze zahraniční SIM v roamingu se lístek koupit nedá.")
        }
        .sheet(isPresented: $showingSimInfo) {
            SimRequirementView(accent: accent)
        }
    }

    /// One-time, dismissible note for users the heuristic flags as probably
    /// foreign. Never blocks: the buttons below stay fully usable.
    private var foreignSimNotice: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.bubble")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("Nákup vyžaduje SIM kartu českého operátora")
                    .font(.brandBold(14, relativeTo: .footnote))
                Text("Lístky se kupují prémiovou SMS. Ze zahraniční SIM v roamingu nedorazí.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("Více informací") { showingSimInfo = true }
                    .font(.footnote.weight(.semibold))
                    .tint(accent)
            }
            Spacer(minLength: 0)
            Button {
                foreignSimNoticeDismissed = true
            } label: {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel("Zavřít upozornění")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.12))
    }

    private var header: some View {
        VStack(spacing: 6) {
            Image("city_\(city.key)")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(height: 92)
                .foregroundStyle(accent)
            Text(city.name)
                .font(.brandBold(22, relativeTo: .title2))
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 24)
        .padding(.bottom, 14)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(city.name)
    }

    private func tap(_ ticket: Ticket) {
        if MessageComposeView.canSendText {
            pending = ticket
        } else {
            cannotSend = true
        }
    }

    @ViewBuilder
    private func row(_ ticket: Ticket) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text("Lístek na \(ticket.duration)")
                    .font(.brandBold(18, relativeTo: .headline))
                Spacer()
                Text("\(ticket.priceKc) Kč")
                    .font(.brandBold(18, relativeTo: .headline))
                    .foregroundStyle(accent)
            }
            if let note = ticket.note, !note.isEmpty {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}
