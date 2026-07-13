import SwiftUI

/// Attribution for the live map (CC-BY 4.0 obligation).
struct DataSourcesView: View {
    var brno: Bool = false
    var accent: Color = .brandTeal
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Legenda") {
                    // Metro is Prague-only; hide it from Brno's legend.
                    ForEach(VehicleKind.allCases.filter { brno ? $0 != .metro : true }, id: \.self) { kind in
                        HStack(spacing: 12) {
                            Circle().fill(kind.color).frame(width: 16, height: 16)
                            Text(kind.displayName(brno: brno))
                            Spacer()
                        }
                    }
                    HStack(spacing: 12) {
                        Circle().stroke(accent, lineWidth: 3.5)
                            .background(Circle().fill(.white)).frame(width: 16, height: 16)
                        Text("Zastávka")
                        Spacer()
                    }
                }

                Section("Živá mapa") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Vozidla a zastávky").font(.headline)
                        Text(brno ? "Magistrát města Brna (data.Brno) / KORDIS JMK"
                                  : "Operátor ICT / Golemio (PID)")
                            .foregroundStyle(.secondary)
                        Link("Licence CC BY 4.0",
                             destination: URL(string: "https://creativecommons.org/licenses/by/4.0/")!)
                            .font(.footnote)
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle("Zdroje dat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Hotovo") { dismiss() }
                }
            }
        }
        .tint(accent)   // sheets present in a fresh environment — re-apply the accent
        .presentationDetents([.medium])
    }
}
