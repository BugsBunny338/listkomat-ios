import SwiftUI

/// Full-screen live map for a city: vehicles + stops, with a failure banner and
/// a data-sources (attribution) button. Portrait, pushed from the ticket screen.
struct LiveMapView: View {
    let city: City
    @StateObject private var vm = LiveMapViewModel()
    @State private var showingSources = false
    @State private var selected: SelectedVehicle?
    @State private var recenterNonce = 0
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("themeId") private var themeId = AppTheme.default.id

    /// Follow the user's chosen theme accent (not a fixed teal).
    private var accent: Color { AppTheme.resolve(themeId).accent }

    var body: some View {
        TransitMapView(vehicles: vm.vehicles, stops: vm.stops,
                       initialCenter: city.coordinate, brno: city.key == "brno",
                       stopNames: vm.stopNames, onSelect: { selected = $0 },
                       recenter: recenterNonce, accent: accent)
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
                if !vm.didLoadOnce {
                    VStack(spacing: 10) {
                        ProgressView().tint(accent)
                        Text("Načítám vozidla…").font(.footnote).foregroundStyle(.secondary)
                    }
                    .padding(18)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                }
            }
            .overlay(alignment: .center) {
                if vm.didLoadOnce && vm.vehicles.isEmpty && !vm.loadFailed {
                    Text("Žádná vozidla v okolí")
                        .font(.subheadline)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(.regularMaterial, in: Capsule())
                }
            }
            .overlay(alignment: .top) {
                if vm.loadFailed {
                    Text("Živá data dočasně nedostupná")
                        .font(.footnote.weight(.medium))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.thinMaterial, in: Capsule())
                        .padding(.top, 4)
                }
            }
            .navigationTitle("Živá mapa – \(city.name)")
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
                else if phase == .background { vm.stop() }  // pause while backgrounded
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
