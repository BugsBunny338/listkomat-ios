import SwiftUI

@main
struct ListkomatApp: App {
    init() {
        Brand.configureNavigationBar()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .tint(.brandTeal)
        }
    }
}
