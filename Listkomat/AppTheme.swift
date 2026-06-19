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
    let band: Color?       // nil = plain system bar (no color band) — the clean look
    let onBand: Color      // text/icon color drawn on the band (used only when band != nil)
    let mascot: String?    // emoji, nil for the clean / black looks
    let isDark: Bool       // dark band → light (white) bar contents + status bar
    var accentOverride: Color? = nil   // when the band color is a poor page accent

    /// Accent used throughout the page (prices, city SVG icons, buttons, the
    /// active-ticket banner). Defaults to the band color so the whole app reads
    /// as one theme. Černá overrides to teal (pure black on the light page is
    /// dull); Čistý has no band, so it falls back to teal — the original look.
    var accent: Color { accentOverride ?? band ?? .brandTeal }

    /// Whether this theme paints a solid color band (vs. the plain system bar).
    var hasBand: Bool { band != nil }

    /// Color scheme for the navigation bar so the system title + status bar pick
    /// a legible color (only meaningful when there's a band).
    var barScheme: ColorScheme { isDark ? .dark : .light }

    /// Čistý (clean, the original look) is the default. Then Černá (hides the
    /// Dynamic Island), the original pink request, the people (Zajíc → wife →
    /// son → Slim), then the places. No standalone teal band — the clean default
    /// already carries the teal accent.
    static let presets: [AppTheme] = [
        AppTheme(id: "clean", name: "Čistý",  band: nil,                  onBand: .ink,   mascot: nil,  isDark: false),
        AppTheme(id: "black", name: "Černá",  band: .black,               onBand: .white, mascot: nil,  isDark: true,  accentOverride: .brandTeal),
        AppTheme(id: "pink",  name: "Růžová", band: Color(hex: 0xFF7EB6), onBand: .ink,   mascot: "🦄", isDark: false),
        AppTheme(id: "zajic", name: "Zajíc",  band: Color(hex: 0xAFA79E), onBand: .ink,   mascot: "🐰", isDark: false),
        AppTheme(id: "zaba",  name: "Žába",   band: Color(hex: 0x4CC76A), onBand: .ink,   mascot: "🐸", isDark: false),
        AppTheme(id: "meda",  name: "Méďa",   band: Color(hex: 0x8B5E3C), onBand: .white, mascot: "🐻", isDark: true),
        AppTheme(id: "slim",  name: "Slim",    band: Color(hex: 0x74B84A), onBand: .ink,   mascot: "🐌", isDark: false),
        AppTheme(id: "evelina", name: "Evelína", band: Color(hex: 0xE0B04A), onBand: .ink, mascot: "🐐", isDark: false),
        AppTheme(id: "brno",  name: "Brno",    band: Color(hex: 0xC8102E), onBand: .white, mascot: "🐉", isDark: true),
        AppTheme(id: "usa",   name: "USA",    band: Color(hex: 0x3C3B6E), onBand: .white, mascot: "🇺🇸", isDark: true),
    ]

    /// Default at first launch is the clean original look.
    static let `default` = resolve("clean")

    /// Resolve a stored id to a theme, falling back to the clean look if unknown
    /// (e.g. a previously-stored "teal" that no longer exists).
    static func resolve(_ id: String) -> AppTheme {
        presets.first { $0.id == id } ?? presets.first { $0.id == "clean" }!
    }
}

/// Light / OS / Dark override for the whole app, applied via
/// `.preferredColorScheme`. "Systém" follows the device setting (the default).
enum AppearanceMode: String, CaseIterable, Identifiable {
    case light, system, dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .light:  return "Světlý"
        case .system: return "Systém"
        case .dark:   return "Tmavý"
        }
    }

    /// nil = follow the operating system.
    var colorScheme: ColorScheme? {
        switch self {
        case .light:  return .light
        case .system: return nil
        case .dark:   return .dark
        }
    }

    static func from(_ raw: String) -> AppearanceMode { AppearanceMode(rawValue: raw) ?? .system }
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
