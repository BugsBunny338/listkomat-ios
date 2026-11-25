import XCTest
import SwiftUI
@testable import Listkomat

/// The Live Activity's orange "čeká na potvrzovací SMS" must read at WCAG AA
/// (with margin) on the lock screen for every theme, in both schemes, as the
/// in-app banner caption does. Plain .orange was ~1.7:1 in light mode.
final class LiveActivityTextTests: XCTestCase {
    private var accents: [UInt32] {
        AppTheme.presets.map { $0.accent.rgbHex } + [0x56C4CF]   // + legacy activities
    }

    /// readable() converges on the modelled lock-screen surfaces, and the shade
    /// stays an orange (never collapses to black or grey).
    func testPendingCaptionConvergesOnTheModelledSurfacesForAllThemes() {
        for accent in accents {
            for dark in [false, true] {
                let caption = RGB(hex: LiveActivityText.pendingCaptionHex(accentHex: accent, dark: dark))
                for surface in LiveActivityText.surfaces(accentHex: accent, dark: dark) {
                    XCTAssertGreaterThanOrEqual(
                        TextContrast.ratio(caption, surface), TextContrast.minRatio,
                        "\(String(accent, radix: 16)) \(dark ? "dark" : "light") on \(String(surface.hex, radix: 16))")
                }
                let (hue, sat, _) = TextContrast.hsl(caption)
                XCTAssertEqual(hue, TextContrast.hsl(LiveActivityText.systemOrange(dark: dark)).h, accuracy: 0.02)
                XCTAssertGreaterThan(sat, 0.5, "still an orange, not a grey")
            }
        }
    }

    func testPlainOrangeFailsInLightAndIsKeptOnBlack() {
        let light = LiveActivityText.surfaces(accentHex: 0x56C4CF, dark: false)
        let orangeLight = LiveActivityText.systemOrange(dark: false)
        let orangeDark = LiveActivityText.systemOrange(dark: true)
        XCTAssertLessThan(TextContrast.ratio(orangeLight, light[0]), TextContrast.minRatio)
        XCTAssertNotEqual(LiveActivityText.pendingCaptionHex(accentHex: 0x56C4CF, dark: false),
                          orangeLight.hex, "light mode must be shaded")
        XCTAssertEqual(LiveActivityText.pendingCaptionHex(accentHex: 0x56C4CF, dark: true),
                       orangeDark.hex, "system orange already reads on black")
        // The dark shade is what Always-On / StandBy get: it must read on black.
        XCTAssertGreaterThanOrEqual(
            TextContrast.ratio(RGB(hex: LiveActivityText.pendingCaptionHex(accentHex: 0x56C4CF, dark: true)),
                               RGB(hex: 0x000000)), TextContrast.minRatio)
    }
}
