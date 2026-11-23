import SwiftUI

/// Manual city override — a grid of the original 2016 city landmark icons
/// (line art in the text accent; black or white on the band when selected).
struct CityPickerView: View {
    let cities: [City]
    let selectedKey: String?
    let accent: Color        // tile fills (band colour)
    let onAccent: Color      // the glyph on the selected (band-filled) tile
    let textAccent: Color    // glyphs on the unselected tiles, the "Zavřít" label
    let onSelect: (City) -> Void

    @Environment(\.dismiss) private var dismiss

    private let columns = [GridItem(.adaptive(minimum: 96, maximum: 150), spacing: 16)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(cities) { city in
                        Button { onSelect(city); dismiss() } label: { tile(city) }
                            .buttonStyle(.plain)
                    }
                }
                .padding()
            }
            .navigationTitle("Vyberte město")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Zavřít") { dismiss() }
                }
            }
        }
        .tint(textAccent)   // sheets present in a fresh environment — re-apply the accent
    }

    @ViewBuilder
    private func tile(_ city: City) -> some View {
        let selected = city.key == selectedKey
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(selected ? accent : accent.opacity(0.12))
                Image("city_\(city.key)")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .padding(18)
                    .foregroundStyle(selected ? onAccent : textAccent)
            }
            .aspectRatio(1, contentMode: .fit)
            Text(city.localizedName)
                .font(.brandBold(13, relativeTo: .caption))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
        }
    }
}
