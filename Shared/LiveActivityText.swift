import SwiftUI

/// Text colours for the Live Activity, shaded with the same rule as the in-app
/// banner (`TextContrast`). In Shared because the widget extension can't reach
/// `AppTheme`; plain hex maths, so no UIKit trait resolution is needed.
enum LiveActivityText {
    /// UIKit's systemOrange in light and dark.
    static let orangeLight = RGB(hex: 0xFF9500)
    static let orangeDark = RGB(hex: 0xFF9F0A)

    /// The lock screen draws the activity on a system material over the
    /// wallpaper, with our accent tint (`backgroundTintAlpha`) on top. Measure on
    /// both ends of each material so the caption reads whatever the wallpaper.
    /// The Dynamic Island is always black: the dark set covers it.
    static let backgroundTintAlpha = 0.12

    static func surfaces(accentHex: UInt32, dark: Bool) -> [RGB] {
        let bases: [UInt32] = dark ? [0x000000, 0x2C2C2E] : [0xFFFFFF, 0xE5E5EA]
        let accent = RGB(hex: accentHex)
        return bases.map { accent.over(RGB(hex: $0), alpha: backgroundTintAlpha) }
    }

    /// "čeká na potvrzovací SMS": systemOrange, shaded until it reads
    /// (light mode darkens it; on black it already reads and stays as is).
    static func pendingCaptionHex(accentHex: UInt32, dark: Bool) -> UInt32 {
        TextContrast.readable(dark ? orangeDark : orangeLight,
                              on: surfaces(accentHex: accentHex, dark: dark)).hex
    }

    static func pendingCaption(accentHex: UInt32, dark: Bool) -> Color {
        Color(hex: pendingCaptionHex(accentHex: accentHex, dark: dark))
    }
}
