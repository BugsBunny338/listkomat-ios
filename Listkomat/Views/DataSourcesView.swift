import SwiftUI

/// Attribution for the live map (CC-BY 4.0 obligation).
struct DataSourcesView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Živá mapa") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Vozidla a zastávky").font(.headline)
                        Text("Magistrát města Brna (data.Brno) / KORDIS JMK")
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
        .presentationDetents([.medium])
    }
}
