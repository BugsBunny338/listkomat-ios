import SwiftUI

/// Full-screen live map for a city: vehicles + stops, with a failure banner and
/// a data-sources (attribution) button. Portrait, pushed from the ticket screen.
struct LiveMapView: View {
    let city: City
    @StateObject private var vm = LiveMapViewModel()
    @State private var showingSources = false

    var body: some View {
        TransitMapView(vehicles: vm.vehicles, stops: vm.stops,
                       initialCenter: city.coordinate, brno: city.key == "brno",
                       stopNames: vm.stopNames)
            .ignoresSafeArea()                       // map floats under the translucent top bar
            .overlay(alignment: .center) {
                if !vm.didLoadOnce {
                    VStack(spacing: 10) {
                        ProgressView()
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
            .sheet(isPresented: $showingSources) { DataSourcesView(brno: city.key == "brno") }
            .onAppear { vm.start() }
            .onDisappear { vm.stop() }
    }
}
