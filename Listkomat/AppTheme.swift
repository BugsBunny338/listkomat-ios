import SwiftUI

/// A pickable look for the app's top bar: band color + a contrast color for the
/// bar's text/icons + an optional emoji mascot. Curated presets (no free color
/// picker) so every choice stays tasteful and readable. Persisted by `id` via
/// `@AppStorage("themeId")`.
///
/// See docs/plans/2026-06-17-listkomat-theme-customization-design.md
struct AppTheme: Identifiable, Hashable {
    let id: String
    let name: String
    let band: Color
    let onBand: Color      // text/icon color drawn on the band
    let mascot: String?    // emoji, nil for the clean "Černá" look
    let isDark: Bool       // dark band → light (white) bar contents + status bar
    var accentOverride: Color? = nil   // when the band color is a poor page accent

    /// Accent used throughout the page (prices, city SVG icons, buttons, the
    /// active-ticket banner). Defaults to the band color so the whole app reads
    /// as one theme — but Černá overrides to teal, because pure black on the
    /// light page is dull and indistinguishable from the system-black labels.
    var accent: Color { accentOverride ?? band }

    /// Color scheme to hand the navigation bar so the system title + status bar
    /// pick a legible color automatically.
    var barScheme: ColorScheme { isDark ? .dark : .light }

    /// Order is intentional: clean black, brand teal, the original pink request,
    /// then the people (Zajíc → wife → son → Slim), then the places.
    static let presets: [AppTheme] = [
        AppTheme(id: "black", name: "Černá",  band: .black,               onBand: .white, mascot: nil,  isDark: true, accentOverride: .brandTeal),
        AppTheme(id: "teal",  name: "Teal",   band: .brandTeal,           onBand: .ink,   mascot: "🚊", isDark: false),
        AppTheme(id: "pink",  name: "Růžová", band: Color(hex: 0xFF7EB6), onBand: .ink,   mascot: "🦄", isDark: false),
        AppTheme(id: "zajic", name: "Zajíc",  band: Color(hex: 0xAFA79E), onBand: .ink,   mascot: "🐰", isDark: false),
        AppTheme(id: "zaba",  name: "Žába",   band: Color(hex: 0x4CC76A), onBand: .ink,   mascot: "🐸", isDark: false),
        AppTheme(id: "meda",  name: "Méďa",   band: Color(hex: 0x8B5E3C), onBand: .white, mascot: "🐻", isDark: true),
        AppTheme(id: "slim",  name: "Slim",   band: Color(hex: 0x74B84A), onBand: .ink,   mascot: "🐌", isDark: false),
        AppTheme(id: "brno",  name: "Brno",   band: Color(hex: 0xC8102E), onBand: .white, mascot: "🐉", isDark: true),
        AppTheme(id: "usa",   name: "USA",    band: Color(hex: 0x3C3B6E), onBand: .white, mascot: "🇺🇸", isDark: true),
    ]

    /// Default at first launch stays the brand teal, independent of list order.
    static let `default` = resolve("teal")

    /// Resolve a stored id to a theme, falling back to teal if unknown.
    static func resolve(_ id: String) -> AppTheme {
        presets.first { $0.id == id } ?? presets.first { $0.id == "teal" }!
    }
}

extension Color {
    /// Build a color from a 0xRRGGBB literal.
    init(hex: UInt32) {
        self.init(
            red:   Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue:  Double(hex & 0xFF) / 255
        )
    }

    /// Soft near-black for text on light bands (gentler than pure black).
    static let ink = Color(white: 0.12)
}
