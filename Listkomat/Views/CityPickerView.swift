import SwiftUI

/// Manual city override. (City-icon grid with the original SVG art comes in M4.)
struct CityPickerView: View {
    let cities: [City]
    let selectedKey: String?
    let onSelect: (City) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(cities) { city in
                Button {
                    onSelect(city)
                    dismiss()
                } label: {
                    HStack {
                        Text(city.name)
                        Spacer()
                        if city.key == selectedKey {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.tint)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .foregroundStyle(.primary)
            }
            .navigationTitle("Vyberte město")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Zavřít") { dismiss() }
                }
            }
        }
    }
}
