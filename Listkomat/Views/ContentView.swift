import SwiftUI

struct ContentView: View {
    @StateObject private var store: CatalogStore
    @StateObject private var location: LocationManager

    @State private var selectedCityKey: String?
    @State private var showingPicker = false

    init() {
        let store = CatalogStore()
        _store = StateObject(wrappedValue: store)
        _location = StateObject(wrappedValue: LocationManager(cities: store.cities))
    }

    /// Manual selection wins; otherwise fall back to the GPS-nearest city.
    private var currentCity: City? {
        let key = selectedCityKey ?? location.nearestCityKey
        return key.flatMap { store.city(forKey: $0) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let city = currentCity {
                    TicketListView(city: city)
                } else {
                    emptyState
                }
            }
            .navigationTitle("Lístkomat")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showingPicker = true
                    } label: {
                        Label("Vybrat město", systemImage: "building.2")
                    }
                }
            }
            .sheet(isPresented: $showingPicker) {
                CityPickerView(
                    cities: store.cities,
                    selectedKey: selectedCityKey ?? location.nearestCityKey
                ) { city in
                    selectedCityKey = city.key
                }
            }
            .onAppear { location.requestAndStart() }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "tram.fill")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Zjišťuji nejbližší město…")
                .font(.brand(17, relativeTo: .body))
                .foregroundStyle(.secondary)
            Button("Vybrat město ručně") { showingPicker = true }
                .buttonStyle(.borderedProminent)
        }
        .padding()
    }
}
