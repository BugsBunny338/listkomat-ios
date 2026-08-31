import SwiftUI

/// Full-screen live map for a city: vehicles + stops, with a failure banner and
/// a data-sources (attribution) button. Portrait, pushed from the ticket screen.
struct LiveMapView: View {
    let city: City
    @StateObject private var vm: LiveMapViewModel
    @State private var showingSources = false
    @State private var selected: SelectedVehicle?
    @State private var recenterNonce = 0
    @State private var connectIsSlow = false
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("themeId") private var themeId = AppTheme.default.id

    init(city: City) {
        self.city = city
        _vm = StateObject(wrappedValue: .make(for: city))
    }

    /// Follow the user's chosen theme accent (not a fixed teal).
    private var accent: Color { AppTheme.resolve(themeId).accent }

    var body: some View {
        TransitMapView(vehicles: vm.vehicles, stops: vm.stops,
                       initialCenter: city.coordinate, brno: city.key == "brno",
                       stopNames: vm.stopNames, onSelect: { selected = $0 },
                       recenter: recenterNonce, accent: accent,
                       stale: vm.showsRetainedPositions)
            .ignoresSafeArea()                       // map floats under the translucent top bar
            .overlay(alignment: .bottomTrailing) {
                Button { recenterNonce += 1 } label: {
                    Image(systemName: "location.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .padding(12)
                        .background(.regularMaterial, in: Circle())
                }
                .tint(accent)
                .padding(.trailing, 16)
                .padding(.bottom, selected == nil ? 28 : 104)   // lift above the card
                .animation(.spring(response: 0.3), value: selected?.id)
            }
            .overlay(alignment: .bottom) {
                if let sel = selected { vehicleCard(sel) }
            }
            .overlay(alignment: .center) {
                // Retained positions take the spinner's place: once there is a
                // (grey) fleet on screen, `didLoadOnce` no longer decides whether
                // the user is looking at an empty map.
                if !vm.didLoadOnce && vm.vehicles.isEmpty { connectingCard }
            }
            .overlay(alignment: .center) {
                if vm.didLoadOnce && vm.vehicles.isEmpty && !vm.loadFailed {
                    Text("Žádná vozidla v okolí")
                        .font(.subheadline)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(.regularMaterial, in: Capsule())
                }
            }
            // One top slot, two things that can claim it. The failure wins: it
            // explains both why the data is old AND that it isn't coming yet,
            // which the "last known positions" wording alone would not.
            .overlay(alignment: .top) {
                if vm.loadFailed {
                    banner(Text("Živá data dočasně nedostupná"))
                } else if vm.showsRetainedPositions {
                    banner(Text("Poslední známé polohy · aktualizuji…"))
                }
            }
            .navigationTitle("Živá mapa – \(city.localizedName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showingSources = true } label: { Image(systemName: "info.circle") }
                        .accessibilityLabel("Zdroje dat")
                }
            }
            .sheet(isPresented: $showingSources) { DataSourcesView(brno: city.key == "brno", accent: accent) }
            .onAppear { vm.start() }
            .onDisappear { vm.stop() }
            .onChange(of: scenePhase) { phase in
                if phase == .active { vm.start() }          // resume on return
                // Pause polling while backgrounded; the socket itself is closed
                // centrally by LiveSources on didEnterBackground.
                else if phase == .background { vm.stop() }
            }
    }

    /// The top status pill — failure, or "these positions aren't live yet".
    private func banner(_ text: Text) -> some View {
        text
            .font(.footnote.weight(.medium))
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(.thinMaterial, in: Capsule())
            .padding(.top, 4)
    }

    /// Seconds of waiting before the cold start is explained rather than just
    /// spun at. Short enough to land well inside a slow connect, long enough
    /// that a warm reopen (which paints almost immediately) never shows it.
    private static let slowConnectHint: TimeInterval = 5

    /// Shown until the first vehicles arrive. Brno's stream does not trickle —
    /// it broadcasts the whole fleet in one burst roughly every 30 s, so a
    /// connect landing just after a burst genuinely waits for the next one
    /// (30.1 s measured against the live feed). That wait is normal, but an
    /// unexplained half-minute of spinner reads as a hang, so after a few
    /// seconds we say why. Prague polls on demand and never waits like this,
    /// hence the Brno-only hint.
    private var connectingCard: some View {
        VStack(spacing: 10) {
            ProgressView().tint(accent)
            Text("Připojuji se k živým datům…")
                .font(.footnote)
                .foregroundStyle(.secondary)
            if connectIsSlow && city.key == "brno" {
                Text("Brno vysílá polohy vozidel přibližně jednou za 30 sekund.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(18)
        .frame(maxWidth: 240)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .animation(.easeInOut(duration: 0.25), value: connectIsSlow)
        .task {
            // Cancelled with the card the moment the first fetch returns, so a
            // fast connect leaves connectIsSlow false and the hint never shows.
            try? await Task.sleep(nanoseconds: UInt64(Self.slowConnectHint * 1_000_000_000))
            guard !Task.isCancelled else { return }
            connectIsSlow = true
        }
    }

    /// Bottom info card for a tapped vehicle: type + line, and where it's heading.
    private func vehicleCard(_ sel: SelectedVehicle) -> some View {
        HStack(spacing: 12) {
            Circle().fill(sel.color).frame(width: 14, height: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text(sel.title).font(.brandBold(17, relativeTo: .headline))
                if let dest = sel.destination {
                    Text("→ \(dest)").font(.subheadline).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button { selected = nil } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 12).padding(.bottom, 12)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .animation(.spring(response: 0.3), value: sel.id)
    }
}
