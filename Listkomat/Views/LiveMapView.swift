import SwiftUI

/// Full-screen live map for a city: vehicles + stops, with a failure banner and
/// a data-sources (attribution) button. Portrait, pushed from the ticket screen.
struct LiveMapView: View {
    let city: City
    @StateObject private var vm = LiveMapViewModel()
    @State private var showingSources = false

    var body: some View {
        TransitMapView(vehicles: vm.vehicles, stops: vm.stops, initialCenter: city.coordinate)
            .ignoresSafeArea(edges: .bottom)
            .overlay(alignment: .top) {
                if vm.loadFailed {
                    Text("Živá data dočasně nedostupná")
                        .font(.footnote.weight(.medium))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.thinMaterial, in: Capsule())
                        .padding(.top, 8)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if vm.vehicles.isEmpty && !vm.loadFailed {
                    EmptyView()
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
            .sheet(isPresented: $showingSources) { DataSourcesView() }
            .onAppear { vm.start() }
            .onDisappear { vm.stop() }
    }
}
