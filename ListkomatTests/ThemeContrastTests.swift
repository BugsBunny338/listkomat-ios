import XCTest
import SwiftUI
@testable import Listkomat

/// G7: the theme accent drawn as text must read at WCAG AA (with margin) on
/// every surface it sits on, for all presets in both schemes, while the band
/// itself stays the theme's own colour.
final class ThemeContrastTests: XCTestCase {
    private func shades(_ theme: AppTheme) -> (light: UInt32, dark: UInt32) {
        AppTheme.textAccentShades(for: theme.accent.rgbHex)
    }

    func testTextAccentReadsOnEverySurfaceForAllThemes() {
        XCTAssertEqual(AppTheme.presets.count, 12)
        for theme in AppTheme.presets {
            let accent = RGB(hex: theme.accent.rgbHex)
            let s = shades(theme)
            for (dark, hex) in [(false, s.light), (true, s.dark)] {
                for surface in AppTheme.textSurfaces(accent: accent, dark: dark) {
                    let ratio = TextContrast.ratio(RGB(hex: hex), surface)
                    XCTAssertGreaterThanOrEqual(ratio, TextContrast.minRatio,
                        "\(theme.id) \(dark ? "dark" : "light") \(String(hex, radix: 16)) on \(String(surface.hex, radix: 16))")
                }
            }
        }
    }

    /// The smallest step: one lightness step back toward the band must fail
    /// somewhere, and an accent that already reads is left alone.
    func testShadeIsTheSmallestStep() {
        for theme in AppTheme.presets {
            let accent = RGB(hex: theme.accent.rgbHex)
            let s = shades(theme)
            for (dark, hex) in [(false, s.light), (true, s.dark)] {
                let surfaces = AppTheme.textSurfaces(accent: accent, dark: dark)
                let shade = RGB(hex: hex)
                if hex == accent.hex { continue }
                let (h, sat, l) = TextContrast.hsl(shade)
                let back = TextContrast.rgb(h: h, s: sat,
                    l: l + (dark ? -1 : 1) * TextContrast.lightnessStep * 1.5)
                let backReads = surfaces.allSatisfy { TextContrast.ratio(back, $0) >= TextContrast.minRatio }
                XCTAssertFalse(backReads, "\(theme.id) \(dark ? "dark" : "light") is shaded further than needed")
            }
        }
    }

    /// Shading moves along the band colour's own hue (within 8-bit rounding).
    func testShadeKeepsHue() {
        for theme in AppTheme.presets where theme.id != "zajic" {   // near-grey: hue is noise
            let accent = RGB(hex: theme.accent.rgbHex)
            let s = shades(theme)
            for hex in [s.light, s.dark] {
                let a = TextContrast.hsl(accent), b = TextContrast.hsl(RGB(hex: hex))
                let dh = abs(a.h - b.h)
                XCTAssertLessThan(min(dh, 1 - dh), 0.01, "\(theme.id) hue drifted")
            }
        }
    }

    /// Bands and fills keep the theme's own colour.
    func testBandsUnchanged() {
        XCTAssertEqual(AppTheme.resolve("pink").accent.rgbHex, 0xFF7EB6)
        XCTAssertEqual(AppTheme.resolve("brno").accent.rgbHex, 0xC8102E)
        XCTAssertEqual(AppTheme.resolve("clean").accent.rgbHex, 0x56C4CF)
        XCTAssertEqual(AppTheme.resolve("black").accent.rgbHex, 0x56C4CF)
        XCTAssertEqual(AppTheme.resolve("usa").band.map { $0.rgbHex }, 0x3C3B6E)
    }

    /// Same rule as Android (listkomat-android#28), so a tester holding both
    /// phones sees the same hue at nearly the same lightness. iOS lands up to
    /// ~0.05 HSL lightness further from the band: its own surfaces (the
    /// bordered button on the banner, the SIM notice tint, elevated sheet rows
    /// in dark mode) are a little darker / lighter than Android's, and
    /// Android's exact values measure 3.9–4.4:1 on them.
    func testMatchesAndroidWithinAShade() {
        let light: [String: UInt32] = ["clean": 0x27717B, "pink": 0xD2005B, "blahovka": 0x916411,
                                       "bomba": 0x916411, "zajic": 0x756B60, "zaba": 0x267A3B,
                                       "slim": 0x4B772F, "evelina": 0x8B6618]
        let dark: [String: UInt32] = ["meda": 0xB47D52, "brno": 0xF14D68, "usa": 0x8483BC]
        for (id, android) in light {
            let ios = shades(AppTheme.resolve(id)).light
            let li = TextContrast.hsl(RGB(hex: ios)).l, la = TextContrast.hsl(RGB(hex: android)).l
            XCTAssertLessThanOrEqual(li, la + 0.005, "\(id): iOS should be no lighter than Android")
            XCTAssertLessThan(la - li, 0.055, "\(id): \(String(ios, radix: 16)) vs Android \(String(android, radix: 16))")
        }
        for (id, android) in dark {
            let ios = shades(AppTheme.resolve(id)).dark
            let li = TextContrast.hsl(RGB(hex: ios)).l, la = TextContrast.hsl(RGB(hex: android)).l
            XCTAssertGreaterThanOrEqual(li, la - 0.005, "\(id): iOS should be no darker than Android")
            XCTAssertLessThan(li - la, 0.055, "\(id): \(String(ios, radix: 16)) vs Android \(String(android, radix: 16))")
        }
    }

    /// Prints the table for the report (light → dark per theme).
    func testPrintShadeTable() {
        for theme in AppTheme.presets {
            let s = shades(theme)
            print(String(format: "G7 shade %@ band %06X light %06X dark %06X",
                         theme.id, theme.accent.rgbHex, s.light, s.dark))
        }
    }
}
