import SwiftUI

@main
struct ListkomatApp: App {
    @AppStorage("themeId") private var themeId = AppTheme.default.id

    init() {
        Brand.configureNavigationBar()
        TicketNotifications.shared.install()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                // App-wide default accent so detached surfaces (alerts, system
                // sheets) follow the theme instead of falling back to fixed teal.
                // Only a fallback: on iOS 27 this closure stops re-running after
                // the first theme switch, so ContentView re-applies the tint (#47).
                .tint(AppTheme.resolve(themeId).textAccent)
        }
    }
}
