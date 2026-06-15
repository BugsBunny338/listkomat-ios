import SwiftUI

/// The list of tickets for the current city. Tapping a ticket opens a
/// pre-filled SMS to that city's number with the ticket code as the body.
struct TicketListView: View {
    let city: City

    @State private var pending: Ticket?
    @State private var cannotSend = false

    var body: some View {
        List {
            Section {
                ForEach(city.tickets) { ticket in
                    Button { tap(ticket) } label: { row(ticket) }
                        .buttonStyle(.plain)
                }
            } header: {
                Text("Lístky – \(city.name)")
            } footer: {
                Text("Po klepnutí se otevře předvyplněná SMS na číslo \(city.smsNumber). Lístek koupíte jejím odesláním.")
            }
        }
        .sheet(item: $pending) { ticket in
            MessageComposeView(recipient: city.smsNumber, body: ticket.code) { _ in
                pending = nil
            }
        }
        .alert("SMS nelze odeslat", isPresented: $cannotSend) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Toto zařízení neumí posílat SMS (např. iPad bez SIM).")
        }
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
                    .font(.headline)
                Spacer()
                Text("\(ticket.priceKc) Kč")
                    .font(.headline)
                    .foregroundStyle(.secondary)
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
