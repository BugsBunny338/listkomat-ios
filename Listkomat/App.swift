import SwiftUI

@main
struct ListkomatApp: App {
    @AppStorage("appearanceMode") private var appearanceMode = AppearanceMode.system.rawValue

    init() {
        Brand.configureNavigationBar()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .tint(.brandTeal)
                .preferredColorScheme(AppearanceMode.from(appearanceMode).colorScheme)
        }
    }
}
