import SwiftUI
import MessageUI

/// The list of tickets for the current city, headed by the city's landmark icon
/// (teal, no tile). Tapping a ticket opens a pre-filled SMS to that city's number.
struct TicketListView: View {
    let city: City
    let updatedAt: String
    let isOffline: Bool
    let liveActivity: LiveActivityController

    @State private var pending: Ticket?
    @State private var cannotSend = false

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
            List {
                Section {
                    ForEach(city.tickets) { ticket in
                        Button { tap(ticket) } label: { row(ticket) }
                            .buttonStyle(.plain)
                    }
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Po klepnutí se otevře předvyplněná SMS na číslo \(city.smsNumber). Lístek koupíte jejím odesláním.")
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
        .sheet(item: $pending) { ticket in
            MessageComposeView(recipient: city.smsNumber, body: ticket.code) { result in
                pending = nil
                if case .sent = result {
                    liveActivity.start(city: city, ticket: ticket)
                }
                #if targetEnvironment(simulator)
                // The simulator can't actually send SMS, so start the Live
                // Activity regardless — lets us demo the time-left countdown.
                liveActivity.start(city: city, ticket: ticket)
                #endif
            }
        }
        .alert("SMS nelze odeslat", isPresented: $cannotSend) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Toto zařízení neumí posílat SMS (např. iPad bez SIM).")
        }
    }

    private var header: some View {
        VStack(spacing: 6) {
            Image("city_\(city.key)")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(height: 92)
                .foregroundStyle(Color.brandTeal)
            Text(city.name)
                .font(.brandBold(22, relativeTo: .title2))
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 6)
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
                    .foregroundStyle(Color.brandTeal)
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
