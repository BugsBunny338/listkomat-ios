import SwiftUI

/// Brand teal #56C4CF — sampled from the original 2016 app icon. Lives in Shared
/// so both the app and the widget extension (Live Activity) can use it.
extension Color {
    static let brandTeal = Color(red: 86 / 255, green: 196 / 255, blue: 207 / 255)

    /// Build a color from a 0xRRGGBB literal. In Shared so the widget can use it too.
    init(hex: UInt32) {
        self.init(
            red:   Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue:  Double(hex & 0xFF) / 255
        )
    }

    /// Pack this color into a 0xRRGGBB value — used to carry the theme accent into
    /// the Live Activity attributes (which must be Codable). Alpha is ignored
    /// (theme accents are opaque). Falls back to brand teal for any color UIKit
    /// can't express as RGB (none of our theme accents hit this).
    var rgbHex: UInt32 {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a) else { return 0x56C4CF }
        func c(_ v: CGFloat) -> UInt32 { UInt32((max(0, min(1, v)) * 255).rounded()) }
        return (c(r) << 16) | (c(g) << 8) | c(b)
    }
}

/// An opaque sRGB colour as 0…1 channels, for contrast math without UIKit.
struct RGB: Equatable {
    var r: Double, g: Double, b: Double

    init(r: Double, g: Double, b: Double) { self.r = r; self.g = g; self.b = b }

    init(hex: UInt32) {
        self.init(r: Double((hex >> 16) & 0xFF) / 255,
                  g: Double((hex >> 8) & 0xFF) / 255,
                  b: Double(hex & 0xFF) / 255)
    }

    var hex: UInt32 {
        func c(_ v: Double) -> UInt32 { UInt32((max(0, min(1, v)) * 255).rounded()) }
        return (c(r) << 16) | (c(g) << 8) | c(b)
    }

    /// This colour at `alpha` composited over `base` (a tinted surface).
    func over(_ base: RGB, alpha: Double) -> RGB {
        RGB(r: base.r + (r - base.r) * alpha,
            g: base.g + (g - base.g) * alpha,
            b: base.b + (b - base.b) * alpha)
    }
}

/// WCAG contrast, and the rule that turns a theme colour into a text colour.
/// The same rule as Android's `GlyphContrast.readableText` (listkomat-android#28),
/// so both apps shade a theme the same way.
enum TextContrast {
    /// WCAG AA for body text is 4.5:1; a hair more because accessibility
    /// scanners round and anti-aliased glyphs measure a little lower.
    static let minRatio = 4.6
    static let lightnessStep = 0.005

    static func luminance(_ c: RGB) -> Double {
        func channel(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b)
    }

    static func ratio(_ a: RGB, _ b: RGB) -> Double { ratio(luminance(a), luminance(b)) }

    private static func ratio(_ l1: Double, _ l2: Double) -> Double {
        (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }

    /// `accent` as text: darkened on light `surfaces`, lightened on dark ones,
    /// hue and saturation kept, by the smallest step that reads at `minRatio`
    /// on every surface. Most theme colours are band colours, too light (or, in
    /// dark mode, too dark) to be text as they are; one that already reads is
    /// returned unchanged.
    static func readable(_ accent: RGB, on surfaces: [RGB]) -> RGB {
        let lums = surfaces.map(luminance)
        func reads(_ c: RGB) -> Bool {
            let l = luminance(c)
            return lums.allSatisfy { ratio(l, $0) >= minRatio }
        }
        if reads(accent) { return accent }
        // Head for whichever extreme reads better against the worst surface.
        let darken = lums.map { ratio(0, $0) }.min()! >= lums.map { ratio(1, $0) }.min()!
        let (h, s, l) = hsl(accent)
        for step in 1...200 {
            let shifted = l + (darken ? -1 : 1) * Double(step) * lightnessStep
            let lightness = max(0, min(1, shifted))
            // Judged as drawn: rounded to 8 bits per channel.
            let candidate = RGB(hex: rgb(h: h, s: s, l: lightness).hex)
            if reads(candidate) || lightness == 0 || lightness == 1 { return candidate }
        }
        return accent
    }

    static func hsl(_ c: RGB) -> (h: Double, s: Double, l: Double) {
        let mx = max(c.r, c.g, c.b), mn = min(c.r, c.g, c.b)
        let l = (mx + mn) / 2
        guard mx != mn else { return (0, 0, l) }
        let d = mx - mn
        let s = l > 0.5 ? d / (2 - mx - mn) : d / (mx + mn)
        let h: Double
        switch mx {
        case c.r: h = (c.g - c.b) / d + (c.g < c.b ? 6 : 0)
        case c.g: h = (c.b - c.r) / d + 2
        default:  h = (c.r - c.g) / d + 4
        }
        return (h / 6, s, l)
    }

    static func rgb(h: Double, s: Double, l: Double) -> RGB {
        guard s != 0 else { return RGB(r: l, g: l, b: l) }
        let q = l < 0.5 ? l * (1 + s) : l + s - l * s
        let p = 2 * l - q
        func channel(_ t0: Double) -> Double {
            let t = (t0 + 1).truncatingRemainder(dividingBy: 1)
            if t < 1.0 / 6 { return p + (q - p) * 6 * t }
            if t < 1.0 / 2 { return q }
            if t < 2.0 / 3 { return p + (q - p) * (2.0 / 3 - t) * 6 }
            return p
        }
        return RGB(r: channel(h + 1.0 / 3), g: channel(h), b: channel(h - 1.0 / 3))
    }
}
