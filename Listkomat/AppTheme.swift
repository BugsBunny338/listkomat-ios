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

    /// The accent as text and icon glyphs on the page, sheets and tinted
    /// surfaces (prices, links, bordered-button labels, the city icon): shaded
    /// per scheme until it reads at `TextContrast.minRatio` on every surface it
    /// sits on. Fills (the band, the selected city tile, map stop rings,
    /// prominent buttons, tinted backgrounds) keep `accent`.
    var textAccent: Color {
        let shades = Self.presetShades[id] ?? Self.textAccentShades(for: accent.rgbHex)
        return Color(uiColor: UIColor { traits in
            UIColor(Color(hex: traits.userInterfaceStyle == .dark ? shades.dark : shades.light))
        })
    }

    static func textAccentShades(for accentHex: UInt32) -> (light: UInt32, dark: UInt32) {
        let accent = RGB(hex: accentHex)
        return (TextContrast.readable(accent, on: textSurfaces(accent: accent, dark: false)).hex,
                TextContrast.readable(accent, on: textSurfaces(accent: accent, dark: true)).hex)
    }

    /// Computed once per preset rather than on every view update.
    private static let presetShades: [String: (light: UInt32, dark: UInt32)] =
        Dictionary(uniqueKeysWithValues: presets.map { ($0.id, textAccentShades(for: $0.accent.rgbHex)) })

    /// Every surface accent text is drawn on, per scheme, with system colours
    /// resolved from UIKit (they shift between iOS releases: iOS 26 has a new
    /// systemOrange). Tints use the opacities the views draw with.
    static func textSurfaces(accent: RGB, dark: Bool) -> [RGB] {
        func system(_ color: UIColor, elevated: Bool = false) -> RGB {
            let traits = UITraitCollection(traitsFrom: [
                UITraitCollection(userInterfaceStyle: dark ? .dark : .light),
                UITraitCollection(userInterfaceLevel: elevated ? .elevated : .base),
            ])
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            color.resolvedColor(with: traits).getRed(&r, green: &g, blue: &b, alpha: &a)
            return RGB(r: max(0, min(1, r)), g: max(0, min(1, g)), b: max(0, min(1, b)))
        }
        let page = system(.systemGroupedBackground)
        let card = system(.secondarySystemGroupedBackground)              // list rows; sheets (elevated systemBackground)
        let sheetRow = system(.secondarySystemGroupedBackground, elevated: true)   // list rows in a sheet
        let orange = system(.systemOrange)
        let banner = accent.over(page, alpha: 0.12)            // active-ticket banner
        return [
            page, card, sheetRow,
            orange.over(page, alpha: 0.12),                    // foreign-SIM notice
            banner,
            accent.over(page, alpha: borderedFillAlpha),       // bordered button on the page ("Živá mapa")
            accent.over(banner, alpha: borderedFillAlpha),     // bordered button on the banner ("Potvrdit nyní")
            accent.over(card, alpha: 0.12),                    // unselected city-picker tile
        ]
    }

    /// `.bordered` buttons fill their capsule with the tint at about this
    /// opacity (measured on the iOS 26 simulator). Those buttons are tinted
    /// with the band and only their label takes `textAccent`, like Android's
    /// tonal container: a capsule tinted with the text shade itself would
    /// darken along with it and force every shade far darker than Android's.
    static let borderedFillAlpha = 0.18

    /// Whether this theme paints a solid color band (vs. the plain system bar).
    var hasBand: Bool { band != nil }

    /// Color scheme for the navigation bar so the system title + status bar pick
    /// a legible color (only meaningful when there's a band).
    var barScheme: ColorScheme { isDark ? .dark : .light }

    /// Čistý (clean, the original look) is the default. Then Černá (hides the
    /// Dynamic Island), the original pink request, the people (Zajíc → wife →
    /// son → Slim), then the places. No standalone teal band — the clean default
    /// already carries the teal accent.
    ///
    /// Localization: only the generic names (Čistý, Černá, Růžová) translate.
    /// The rest — Bláhovka, Bomba, Zajíc, Žába, Méďa, Slim, Evelína, Brno,
    /// USA — are proper nouns / family nicknames and deliberately stay the
    /// same in every language, which is why they're plain literals with no
    /// catalog entry.
    static let presets: [AppTheme] = [
        AppTheme(id: "clean", name: String(localized: "Čistý"),  band: nil,                  onBand: .ink,   mascot: nil,  isDark: false),
        AppTheme(id: "black", name: String(localized: "Černá"),  band: .black,               onBand: .white, mascot: nil,  isDark: true,  accentOverride: .brandTeal),
        AppTheme(id: "pink",  name: String(localized: "Růžová"), band: Color(hex: 0xFF7EB6), onBand: .ink,   mascot: "🦄", isDark: false),
        AppTheme(id: "blahovka", name: "Bláhovka", band: Color(hex: 0xE6A52C), onBand: .ink, mascot: "🍺", isDark: false),
        AppTheme(id: "bomba", name: "Bomba",  band: Color(hex: 0xE6A52C), onBand: .ink, mascot: "💣", isDark: false),
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
        case .light:  return String(localized: "Světlý")
        case .system: return String(localized: "Systém")
        case .dark:   return String(localized: "Tmavý")
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
    // Color(hex:) now lives in Shared/BrandColor.swift so the widget can use it too.

    /// Soft near-black for text on light bands (gentler than pure black).
    static let ink = Color(white: 0.12)
}
