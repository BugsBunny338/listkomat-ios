import SwiftUI

struct ContentView: View {
    @StateObject private var store: CatalogStore
    @StateObject private var location: LocationManager
    @StateObject private var liveActivity = LiveActivityController()

    @State private var selectedCityKey: String?
    @State private var showingPicker = false
    @State private var showingPrimer = false

    init() {
        let store = CatalogStore()
        _store = StateObject(wrappedValue: store)
        _location = StateObject(wrappedValue: LocationManager(cities: store.cities))
    }

    /// Manual selection wins; otherwise the GPS-nearest city, but only if it's
    /// close enough to plausibly be where the user actually is.
    private var currentCity: City? {
        if let key = selectedCityKey { return store.city(forKey: key) }
        guard let key = location.nearestCityKey,
              let dist = location.nearestDistanceKm,
              dist <= LocationManager.maxDefaultDistanceKm else { return nil }
        return store.city(forKey: key)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let active = liveActivity.active {
                    activeTicketBanner(active)
                }
                if let city = currentCity {
                    TicketListView(
                        city: city,
                        updatedAt: store.catalog.updatedAt,
                        isOffline: store.refreshFailed,
                        liveActivity: liveActivity
                    )
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
                    selectedKey: currentCity?.key
                ) { city in
                    selectedCityKey = city.key
                }
            }
            .sheet(isPresented: $showingPrimer) {
                LocationPrimerView(
                    onAllow: {
                        showingPrimer = false
                        location.requestPermission()
                    },
                    onManual: {
                        showingPrimer = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                            showingPicker = true
                        }
                    }
                )
            }
            .onAppear(perform: handleAppear)
            .onChange(of: location.authorization) { status in
                if status == .authorizedWhenInUse || status == .authorizedAlways {
                    location.start()
                }
            }
            .task { await store.refresh() }
        }
    }

    private func handleAppear() {
        switch location.authorization {
        case .notDetermined:
            showingPrimer = true
        case .authorizedWhenInUse, .authorizedAlways:
            location.start()
        default:
            break
        }
    }

    // MARK: - Active ticket banner (manual end)

    private func activeTicketBanner(_ active: LiveActivityController.ActiveTicket) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "tram.fill")
                .foregroundStyle(Color.brandTeal)
            VStack(alignment: .leading, spacing: 1) {
                Text("Aktivní lístek")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("\(active.cityName) · \(active.ticketLabel)")
                    .font(.brandBold(15, relativeTo: .subheadline))
            }
            Spacer()
            Button("Ukončit") { liveActivity.stop() }
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.bordered)
                .tint(.red)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.brandTeal.opacity(0.12))
    }

    // MARK: - Empty state (no city to show)

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: emptyIcon)
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(emptyTitle)
                .font(.brandBold(18, relativeTo: .headline))
                .multilineTextAlignment(.center)
            if let subtitle = emptySubtitle {
                Text(subtitle)
                    .font(.brand(15, relativeTo: .subheadline))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button("Vybrat město") { showingPicker = true }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxHeight: .infinity)
        .padding(32)
    }

    private var isDenied: Bool {
        location.authorization == .denied || location.authorization == .restricted
    }

    private var emptyIcon: String {
        if location.isFarFromAllCities { return "mappin.slash" }
        if isDenied { return "location.slash" }
        return "location.magnifyingglass"
    }

    private var emptyTitle: String {
        if location.isFarFromAllCities { return "Žádné město v okolí" }
        if isDenied { return "Poloha není povolená" }
        return "Zjišťuji nejbližší město…"
    }

    private var emptySubtitle: String? {
        if location.isFarFromAllCities {
            if let key = location.nearestCityKey,
               let name = store.city(forKey: key)?.name,
               let dist = location.nearestDistanceKm {
                return "Nejbližší podporované město (\(name)) je ~\(Int(dist)) km daleko. Vyberte město ručně."
            }
            return "Jste daleko od podporovaných měst. Vyberte město ručně."
        }
        if isDenied {
            return "Vyberte město ručně, nebo povolte polohu v Nastavení."
        }
        return nil
    }
}
