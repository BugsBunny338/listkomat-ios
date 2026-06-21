import SwiftUI

@main
struct ListkomatApp: App {
    @AppStorage("themeId") private var themeId = AppTheme.default.id

    init() {
        Brand.configureNavigationBar()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                // App-wide default accent so detached surfaces (alerts, system
                // sheets) follow the theme instead of falling back to fixed teal.
                .tint(AppTheme.resolve(themeId).accent)
        }
    }
}
