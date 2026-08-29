import SwiftUI

/// The permanent explanation of the Czech-SIM requirement (issue #15).
///
/// One screen, three entry points: the one-time note for probable foreigners,
/// the always-present footer link on the ticket list, and the alert shown when
/// an SMS actually fails to send. Keeping the copy in one place means the three
/// never drift apart.
struct SimRequirementView: View {
    var accent: Color = .brandTeal
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Jak nákup funguje") {
                    Text("Lístek koupíte odesláním předvyplněné SMS. Platbu vyúčtuje váš mobilní operátor, neplatíte přes App Store.")
                }

                Section("Potřebujete českou SIM kartu") {
                    Text("Prémiové SMS umí zpracovat jen čeští operátoři (O2, T‑Mobile, Vodafone a jejich virtuální sítě). Předplacená karta stačí.")
                }

                Section("Zahraniční SIM v roamingu") {
                    Text("SMS se obvykle tváří, že odešla, ale lístek nedorazí. Appka se to nemá jak dozvědět — iOS jí nedovolí číst příchozí SMS — proto raději upozorňujeme dopředu.")
                }
            }
            .navigationTitle("Placení SMS")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Hotovo") { dismiss() }
                }
            }
        }
        .tint(accent)   // sheets present in a fresh environment — re-apply the accent
        .presentationDetents([.medium, .large])
    }
}
