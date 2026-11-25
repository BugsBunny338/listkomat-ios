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

    func testPendingCaptionReadsOnTheLockScreenForAllThemes() {
        for accent in accents {
            for dark in [false, true] {
                let caption = RGB(hex: LiveActivityText.pendingCaptionHex(accentHex: accent, dark: dark))
                for surface in LiveActivityText.surfaces(accentHex: accent, dark: dark) {
                    XCTAssertGreaterThanOrEqual(
                        TextContrast.ratio(caption, surface), TextContrast.minRatio,
                        "\(String(accent, radix: 16)) \(dark ? "dark" : "light") on \(String(surface.hex, radix: 16))")
                }
            }
        }
    }

    func testPlainOrangeFailsInLightAndIsKeptOnBlack() {
        let light = LiveActivityText.surfaces(accentHex: 0x56C4CF, dark: false)
        XCTAssertLessThan(TextContrast.ratio(LiveActivityText.orangeLight, light[0]), TextContrast.minRatio)
        XCTAssertNotEqual(LiveActivityText.pendingCaptionHex(accentHex: 0x56C4CF, dark: false),
                          LiveActivityText.orangeLight.hex, "light mode must be shaded")
        XCTAssertEqual(LiveActivityText.pendingCaptionHex(accentHex: 0x56C4CF, dark: true),
                       LiveActivityText.orangeDark.hex, "system orange already reads on black")
    }
}
