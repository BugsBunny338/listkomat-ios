import SwiftUI

struct ContentView: View {
    @StateObject private var store: CatalogStore
    @StateObject private var location: LocationManager
    @StateObject private var liveActivity = LiveActivityController()

    @State private var selectedCityKey: String?
    @State private var showingPicker = false
    @State private var showingPrimer = false
    @State private var showingTheme = false
    @State private var drops: [RainDrop] = []
    @State private var rainTaps = 0

    @AppStorage("themeId") private var themeId = AppTheme.default.id
    private var theme: AppTheme { AppTheme.resolve(themeId) }

    /// Bar buttons: contrast color on a colored band, the accent on the plain bar.
    private var barItemColor: Color { theme.hasBand ? theme.onBand : theme.accent }

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
                        liveActivity: liveActivity,
                        accent: theme.accent
                    )
                } else {
                    emptyState
                }
            }
            .navigationTitle("Lístkomat")
            .modifier(ThemedBar(theme: theme))
            .tint(theme.accent)
            .toolbar {
                if let mascot = theme.mascot {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button { rain(mascot) } label: {
                            Text(mascot).font(.system(size: 20))
                        }
                        .accessibilityLabel("Déšť")
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showingTheme = true
                    } label: {
                        Label("Vzhled", systemImage: "paintbrush")
                    }
                    .tint(barItemColor)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showingPicker = true
                    } label: {
                        Label("Vybrat město", systemImage: "building.2")
                    }
                    .tint(barItemColor)
                }
            }
            .sheet(isPresented: $showingTheme) {
                ThemeSheet(themeId: $themeId)
            }
            .sheet(isPresented: $showingPicker) {
                CityPickerView(
                    cities: store.cities,
                    selectedKey: currentCity?.key,
                    accent: theme.accent
                ) { city in
                    selectedCityKey = city.key
                }
            }
            .sheet(isPresented: $showingPrimer) {
                LocationPrimerView(
                    accent: theme.accent,
                    onContinue: {
                        showingPrimer = false
                        location.requestPermission()
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
        .overlay(EmojiRainOverlay(drops: drops))
    }

    /// Easter egg: tapping the mascot rains it across the screen; rapid repeat
    /// taps pile up for a heavier downpour.
    private func rain(_ emoji: String) {
        rainTaps += 1
        let count = min(10 + rainTaps * 6, 60)
        let batch = RainDrop.burst(emoji, count: count)
        drops.append(contentsOf: batch)
        let ids = Set(batch.map(\.id))
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
            drops.removeAll { ids.contains($0.id) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            if rainTaps > 0 { rainTaps -= 1 }
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
                .foregroundStyle(theme.accent)
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
        .background(theme.accent.opacity(0.12))
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

/// Paints the nav bar with the theme's color band (inline title) when it has
/// one; otherwise leaves the plain system bar with a large title — the clean,
/// pre-theming look that "Čistý" restores.
private struct ThemedBar: ViewModifier {
    let theme: AppTheme

    func body(content: Content) -> some View {
        if let band = theme.band {
            content
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(band, for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
                .toolbarColorScheme(theme.barScheme, for: .navigationBar)
        } else {
            content
                .navigationBarTitleDisplayMode(.large)
        }
    }
}
