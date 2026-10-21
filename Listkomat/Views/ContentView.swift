import SwiftUI

struct ContentView: View {
    @StateObject private var store: CatalogStore
    @StateObject private var location: LocationManager
    @StateObject private var liveActivity = LiveActivityController()

    /// The manual pick as a session override of GPS (`CitySelection`); set
    /// again from the persisted pick on a return within the grace window.
    @State private var manualCityKey: String?
    /// True while this process's first fix may still beat the fallback.
    @State private var awaitingFirstFix = false
    /// Lets only the latest hold end `awaitingFirstFix`.
    @State private var holdGeneration = 0
    /// A return to the app is `.active` after `.background`, not after a brief
    /// `.inactive` (Control Center, a system alert).
    @State private var wasInBackground = false
    @State private var showingPicker = false
    @State private var showingPrimer = false
    @State private var showingTheme = false
    @State private var rainNonce = 0

    @AppStorage("themeId") private var themeId = AppTheme.default.id
    @AppStorage("appearanceMode") private var appearanceMode = AppearanceMode.system.rawValue
    /// Last city whose live map the user actually opened, written by
    /// `LiveMapView`. Read here purely as a prefetch hint (#31) — it never
    /// decides what's on screen, so a user who has moved cities loses one
    /// speculative burst, not a correct city screen.
    @AppStorage("lastLiveCityKey") private var lastLiveCityKey = ""
    /// The last manual pick, persisted only as the fallback for when GPS can't
    /// deliver ("" = none).
    @AppStorage("fallbackCityKey") private var fallbackCityKey = ""
    /// When the manual override was last on screen: the pick, then every
    /// departure from the app while it still overrode GPS (0 = never).
    @AppStorage("overrideSeenAt") private var overrideSeenAt: Double = 0

    @Environment(\.scenePhase) private var scenePhase

    private var theme: AppTheme { AppTheme.resolve(themeId) }

    /// Forced page appearance from the Režim toggle (nil = follow the system).
    private var contentScheme: ColorScheme? { AppearanceMode.from(appearanceMode).colorScheme }

    /// Bar buttons: contrast color on a colored band, the text accent on the plain bar.
    private var barItemColor: Color { theme.hasBand ? theme.onBand : theme.textAccent }

    init() {
        let store = CatalogStore()
        _store = StateObject(wrappedValue: store)
        _location = StateObject(wrappedValue: LocationManager(cities: store.cities))
    }

    /// This session's manual pick, else the GPS-nearest city within reach,
    /// else the last pick — see `CitySelection`.
    private var currentCity: City? {
        let key = CitySelection.cityKey(manual: manualCityKey,
                                        location: location.state,
                                        fallback: fallbackCityKey.isEmpty ? nil : fallbackCityKey,
                                        awaitingFirstFix: awaitingFirstFix)
        return key.flatMap(store.city(forKey:))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                titleHeader
                if let active = liveActivity.active {
                    activeTicketBanner(active)
                }
                if let city = currentCity {
                    // A city that changes by itself (a late fix) fades in, and
                    // its rows ignore taps for a moment (TicketListView): a tap
                    // aimed at the previous list must not buy a ticket here.
                    TicketListView(
                        city: city,
                        updatedAt: store.catalog.updatedAt,
                        isOffline: store.refreshFailed,
                        liveActivity: liveActivity,
                        accent: theme.accent,
                        textAccent: theme.textAccent
                    )
                    .id(city.key)
                    .transition(.opacity)
                } else {
                    emptyState
                }
            }
            .animation(.easeInOut(duration: 0.3), value: currentCity?.key)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemGroupedBackground))
            .navigationTitle("")
            .modifier(ThemedBar(theme: theme, contentScheme: contentScheme))
            // The tint mostly colours text (button labels, links), so it takes
            // the text shade; fills that want the band set it themselves.
            .tint(theme.textAccent)
            .toolbar {
                if let mascot = theme.mascot {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button { rain() } label: {
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
                    accent: theme.accent,
                    textAccent: theme.textAccent
                ) { city in
                    fallbackCityKey = city.key
                    manualCityKey = city.key
                    overrideSeenAt = Date().timeIntervalSince1970
                }
            }
            .sheet(isPresented: $showingPrimer) {
                LocationPrimerView(
                    accent: theme.accent,
                    textAccent: theme.textAccent,
                    onContinue: {
                        showingPrimer = false
                        location.requestPermission()
                    }
                )
            }
            .onAppear(perform: handleAppear)
            .onChange(of: location.authorization) { _ in
                // Granted from the primer: locate now, holding the fallback as at launch.
                locate()
            }
            .onChange(of: location.isLocating) { locating in
                // After the fix lands (or the attempt ends), so the fallback
                // never flashes in between.
                if !locating { awaitingFirstFix = false }
            }
            .onChange(of: scenePhase) { phase in
                switch phase {
                case .active:
                    // Foregrounding is the same cold case as launch: the central
                    // background close drops every socket behind us.
                    prefetchLiveSource()
                    // A ticket may have expired while we were suspended.
                    liveActivity.refresh()
                    if wasInBackground {
                        wasInBackground = false
                        appStarted()
                    }
                case .background:
                    wasInBackground = true
                    appStopped()
                default:
                    break
                }
            }
            .task { await store.refresh() }
        }
        .overlay(RainLayer(trigger: rainNonce))
        .modifier(ForcedScheme(scheme: contentScheme))
    }

    /// Large in-content title so the color band only paints the slim top bar,
    /// not the whole top zone. Color follows the page appearance.
    private var titleHeader: some View {
        Text("Lístkomat")
            .font(.brandBold(34, relativeTo: .largeTitle))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 4)
    }

    /// Easter egg: tapping the mascot rains it across the screen. Just bumps a
    /// nonce — RainLayer resolves the current mascot from @AppStorage(themeId) at
    /// burst time, so even if this toolbar button's closure is stale the right
    /// mascot rains. Rapid repeat taps pile up for a heavier downpour (in RainLayer).
    private func rain() {
        rainNonce += 1
    }

    /// Start filling the live snapshot as early as the app can (#31).
    ///
    /// The city screen's keep-warm can only start once `currentCity` resolves,
    /// which waits on a CoreLocation fix or a manual pick — seconds we could
    /// have spent connected. This doesn't wait for either. It is aimed at the
    /// last live-map city the user saw rather than fired at every city: one
    /// KORDIS burst is ~320 KB, far too much to spend speculatively on a city
    /// the user doesn't travel in. With nothing remembered yet (first launch)
    /// we spend nothing and the city screen's keep-warm takes it from there.
    /// Re-resolved against the current catalog every time, never trusted from
    /// storage alone: `liveMapDisabled` is the remote kill switch for a broken
    /// feed, and a prefetch that skipped this check would keep opening the socket
    /// on every launch with no way to stop it short of an App Store release. It
    /// also keeps a stale key for a removed city from reaching
    /// `LiveSources.makeSource`, whose default branch is Brno's stream.
    private func prefetchLiveSource() {
        guard let city = store.city(forKey: lastLiveCityKey), city.showsLiveMap else { return }
        LiveSources.prefetch(cityKey: city.key)
    }

    private func handleAppear() {
        // onAppear rather than only scenePhase: the scene is already .active at
        // launch, so onChange never fires for it.
        prefetchLiveSource()
        appStarted()
        // The primer is for first runs with nothing to show; a remembered pick
        // shows without asking.
        if location.authorization == .notDetermined && currentCity == nil {
            showingPrimer = true
        }
    }

    // MARK: - City rule (CitySelection)

    /// Launch and every return from the background: an old manual pick stops
    /// overriding GPS and, with permission, one new fix is taken. The city
    /// changes only here, never mid-use.
    private func appStarted() {
        manualCityKey = CitySelection.overrideAfterStart(
            fallback: fallbackCityKey.isEmpty ? nil : fallbackCityKey,
            lastSeenAt: overrideSeenAt > 0 ? Date(timeIntervalSince1970: overrideSeenAt) : nil,
            now: Date())
        locate()
    }

    /// The grace counts from leaving, not from the pick: browsing for ten
    /// minutes and then sending the ticket SMS must not flip the city.
    private func appStopped() {
        guard manualCityKey != nil else { return }
        overrideSeenAt = Date().timeIntervalSince1970
    }

    private func locate() {
        guard location.isAuthorized, !location.isLocating else { return }
        // A fix from earlier in this process stays on screen while the new one
        // comes in. Without one, hold the fallback back briefly: the fix usually
        // takes about a second, and a list that swaps cities under the thumb can
        // sell the wrong ticket.
        if location.nearestCityKey == nil {
            awaitingFirstFix = true
            holdGeneration += 1
            let generation = holdGeneration
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(CitySelection.firstFixHold * 1_000_000_000))
                if generation == holdGeneration { awaitingFirstFix = false }
            }
        }
        location.requestFix()
    }

    // MARK: - Active ticket banner (countdown + manual end)

    /// The in-app twin of the Live Activity, driven by the stored ticket so it
    /// works with Live Activities off: pending (countdown to validity + Potvrdit
    /// nyní) → valid (time left + "Platí do") → expired (Ukončit dismisses it).
    private func activeTicketBanner(_ active: ActiveTicket) -> some View {
        // TimelineView so the banner changes phase on its own at validFrom and
        // endDate while the app is open (no push needed in-app).
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            // `ctx.date` is the current *schedule entry*, which lags real time by up to
            // a tick. `confirmNow()` re-anchors validFrom to the tap instant, so
            // comparing against the entry alone left "Potvrdit nyní" on screen for up to
            // a second after a successful tap — inviting the second tap that #19 is
            // about, which would re-anchor the ticket's window again. Take whichever
            // clock is further along.
            let timeline = active.timeline
            let phase = timeline.phase(at: max(ctx.date, .now))
            let pending = phase == .pending
            HStack(spacing: 12) {
                Image(systemName: "tram.fill")
                    .foregroundStyle(phase == .expired ? AnyShapeStyle(.secondary) : AnyShapeStyle(theme.textAccent))
                VStack(alignment: .leading, spacing: 1) {
                    Group {
                        switch phase {
                        case .pending: Text("Čeká na potvrzovací SMS").foregroundStyle(.orange)
                        case .valid: Text("Aktivní lístek").foregroundStyle(.secondary)
                        case .expired: Text("Jízdenka vypršela").foregroundStyle(.secondary)
                        }
                    }
                    .font(.caption2)
                    Text("\(bannerCityName(active)) · \(active.ticketLabel)")
                        .font(.brandBold(15, relativeTo: .subheadline))
                    switch phase {
                    case .pending:
                        // Same countdown to validity as the Live Activity.
                        Text("platí za \(Text(timerInterval: timeline.sentAt...timeline.validFrom, countsDown: true))")
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    case .valid:
                        Text("Platí do \(timeline.endDate, style: .time)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    case .expired:
                        EmptyView()
                    }
                }
                Spacer(minLength: 4)
                if phase == .valid {
                    Text(timerInterval: timeline.validFrom...timeline.endDate, countsDown: true)
                        .font(.title3.weight(.semibold))
                        .monospacedDigit()
                        .multilineTextAlignment(.trailing)
                }
                if pending {
                    Button { liveActivity.confirmNow() } label: {
                        Text("Potvrdit nyní").foregroundStyle(theme.textAccent)
                    }
                    .font(.subheadline.weight(.semibold))
                    .buttonStyle(.bordered)
                    .tint(theme.accent)   // band-tinted capsule (a fill), text-accent label
                }
                Button("Ukončit") { liveActivity.stop() }
                    .font(.subheadline.weight(.semibold))
                    .buttonStyle(.bordered)
                    .tint(.red)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(phase == .expired ? Color(.tertiarySystemFill) : theme.accent.opacity(0.12))
        }
    }

    /// The city in the current app language when the ticket knows its key
    /// (the stored name is from purchase time).
    private func bannerCityName(_ active: ActiveTicket) -> String {
        active.cityKey.flatMap { store.city(forKey: $0)?.localizedName } ?? active.cityName
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
                .tint(theme.accent)   // a fill: keeps the band colour
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
        if location.isFarFromAllCities { return String(localized: "Žádné město v okolí") }
        if isDenied { return String(localized: "Poloha není povolená") }
        return String(localized: "Zjišťuji nejbližší město…")
    }

    private var emptySubtitle: String? {
        if location.isFarFromAllCities {
            if let key = location.nearestCityKey,
               let name = store.city(forKey: key)?.localizedName,
               let dist = location.nearestDistanceKm {
                return String(localized: "Nejbližší podporované město (\(name)) je ~\(Int(dist)) km daleko. Vyberte město ručně.")
            }
            return String(localized: "Jste daleko od podporovaných měst. Vyberte město ručně.")
        }
        if isDenied {
            return String(localized: "Vyberte město ručně, nebo povolte polohu v Nastavení.")
        }
        return nil
    }
}

/// Paints the slim top bar with the theme's color band when it has one. The
/// status-bar/title contrast follows whatever sits behind the status bar: the
/// band's darkness for a colored theme, or the page appearance for Čistý — so a
/// black bar on a light page still gets a legible white status bar.
private struct ThemedBar: ViewModifier {
    let theme: AppTheme
    let contentScheme: ColorScheme?

    func body(content: Content) -> some View {
        if let band = theme.band {
            content
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(band, for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
                .toolbarColorScheme(theme.barScheme, for: .navigationBar)
        } else if let cs = contentScheme {
            // Čistý: plain bar, but match the status bar to the forced page scheme.
            content
                .navigationBarTitleDisplayMode(.inline)
                .toolbarColorScheme(cs, for: .navigationBar)
        } else {
            content
                .navigationBarTitleDisplayMode(.inline)
        }
    }
}

/// Forces the page (content + sheets) to light/dark via the SwiftUI environment
/// without touching the window — so it doesn't override the status-bar color the
/// bar sets. nil = follow the system.
private struct ForcedScheme: ViewModifier {
    let scheme: ColorScheme?

    func body(content: Content) -> some View {
        if let scheme {
            content.environment(\.colorScheme, scheme)
        } else {
            content
        }
    }
}
