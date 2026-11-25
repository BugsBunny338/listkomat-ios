import SwiftUI
import UIKit

/// Text colours for the Live Activity, shaded with the same rule as the in-app
/// banner (`TextContrast`). In Shared because the widget extension can't reach
/// `AppTheme`.
enum LiveActivityText {
    /// UIKit's systemOrange for a scheme, as opaque sRGB (the same colour the
    /// in-app banner caption starts from).
    static func systemOrange(dark: Bool) -> RGB {
        let traits = UITraitCollection(userInterfaceStyle: dark ? .dark : .light)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor.systemOrange.resolvedColor(with: traits).getRed(&r, green: &g, blue: &b, alpha: &a)
        return RGB(r: max(0, min(1, r)), g: max(0, min(1, g)), b: max(0, min(1, b)))
    }

    /// The lock screen draws the activity on a system material over the
    /// wallpaper, with our accent tint (`backgroundTintAlpha`) on top. Measure on
    /// both ends of each material so the caption reads whatever the wallpaper
    /// (#D1D1D6: a light material over a dark wallpaper, conservatively).
    /// The Dynamic Island, Always-On and StandBy are dark: the dark set covers them.
    static let backgroundTintAlpha = 0.12

    static func surfaces(accentHex: UInt32, dark: Bool) -> [RGB] {
        let bases: [UInt32] = dark ? [0x000000, 0x2C2C2E] : [0xFFFFFF, 0xD1D1D6]
        let accent = RGB(hex: accentHex)
        return bases.map { accent.over(RGB(hex: $0), alpha: backgroundTintAlpha) }
    }

    /// "čeká na potvrzovací SMS": systemOrange, shaded until it reads
    /// (light backdrops darken it; on black it already reads and stays as is).
    static func pendingCaptionHex(accentHex: UInt32, dark: Bool) -> UInt32 {
        TextContrast.readable(systemOrange(dark: dark),
                              on: surfaces(accentHex: accentHex, dark: dark)).hex
    }

    static func pendingCaption(accentHex: UInt32, dark: Bool) -> Color {
        Color(hex: pendingCaptionHex(accentHex: accentHex, dark: dark))
    }
}
