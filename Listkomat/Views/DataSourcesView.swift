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
                    // Metro and the Vltava ferries are Prague-only; hide both from Brno's legend.
                    ForEach(VehicleKind.allCases.filter {
                        brno ? ($0 != .metro && $0 != .ferry) : true
                    }, id: \.self) { kind in
                        HStack(spacing: 12) {
                            legendSwatch(kind)
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

    /// Metro shows one lettered dot per line; every other kind shows a single dot.
    /// Both sit in the same fixed width so the labels line up.
    @ViewBuilder
    private func legendSwatch(_ kind: VehicleKind) -> some View {
        HStack(spacing: 4) {
            if kind == .metro {
                ForEach(["A", "B", "C"], id: \.self) { line in
                    metroDot(line)
                }
            } else {
                Circle()
                    .fill(TransitPalette.fill(for: kind, line: ""))
                    .frame(width: 16, height: 16)
            }
        }
        .frame(width: 56, alignment: .leading)   // 3 × 16 + 2 × 4, so rows align
    }

    /// One metro line's swatch: its colour, with its letter in the readable ink.
    private func metroDot(_ line: String) -> some View {
        let style = TransitPalette.style(for: .metro, line: line)
        return ZStack {
            Circle().fill(style.fill)
            Text(line)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(style.glyph)
        }
        .frame(width: 16, height: 16)
    }
}
