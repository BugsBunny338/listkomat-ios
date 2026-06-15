import SwiftUI
import UIKit

/// Lístkomat brand: the original teal (see Shared/BrandColor.swift) + Alte Haas
/// Grotesk (freeware, license bundled in Resources/Fonts). Font used for titles
/// & headlines only; body stays the system font for legibility and Dynamic Type.
enum Brand {
    static let regular = "AlteHaasGrotesk"        // PostScript name
    static let bold = "AlteHaasGrotesk_Bold"

    /// Brand the navigation bar large/inline titles. Call once at launch.
    static func configureNavigationBar() {
        let appearance = UINavigationBarAppearance()
        appearance.configureWithDefaultBackground()
        if let large = UIFont(name: bold, size: 34) {
            appearance.largeTitleTextAttributes = [.font: large]
        }
        if let inline = UIFont(name: bold, size: 17) {
            appearance.titleTextAttributes = [.font: inline]
        }
        UINavigationBar.appearance().standardAppearance = appearance
        UINavigationBar.appearance().scrollEdgeAppearance = appearance
        UINavigationBar.appearance().compactAppearance = appearance
    }
}

extension Font {
    static func brand(_ size: CGFloat, relativeTo style: Font.TextStyle = .body) -> Font {
        .custom(Brand.regular, size: size, relativeTo: style)
    }

    static func brandBold(_ size: CGFloat, relativeTo style: Font.TextStyle = .headline) -> Font {
        .custom(Brand.bold, size: size, relativeTo: style)
    }
}
