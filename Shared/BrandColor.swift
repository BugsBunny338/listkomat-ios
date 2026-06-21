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
    /// the Live Activity attributes (which must be Codable).
    var rgbHex: UInt32 {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a)
        func c(_ v: CGFloat) -> UInt32 { UInt32((max(0, min(1, v)) * 255).rounded()) }
        return (c(r) << 16) | (c(g) << 8) | c(b)
    }
}
