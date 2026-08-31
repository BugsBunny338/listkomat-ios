import XCTest
import SwiftUI
@testable import Listkomat

final class TransitPaletteTests: XCTestCase {

    // MARK: Metro is coloured per line

    func testMetroLinesUseTheOfficialColours() {
        XCTAssertEqual(TransitPalette.fill(for: .metro, line: "A").rgbHex, 0x00A05A)
        XCTAssertEqual(TransitPalette.fill(for: .metro, line: "B").rgbHex, 0xFFCE00)
        XCTAssertEqual(TransitPalette.fill(for: .metro, line: "C").rgbHex, 0xE1252B)
    }

    func testMetroLinesAreMutuallyDistinct() {
        let fills = ["A", "B", "C"].map { TransitPalette.fill(for: .metro, line: $0).rgbHex }
        XCTAssertEqual(Set(fills).count, 3)
    }

    /// A feed anomaly must degrade to the pre-2.4 amber, never to an uncoloured pin.
    func testUnknownMetroLineFallsBackToAmber() {
        XCTAssertEqual(TransitPalette.fill(for: .metro, line: "D").rgbHex, 0xE0812B)
        XCTAssertEqual(TransitPalette.fill(for: .metro, line: "").rgbHex, 0xE0812B)
        XCTAssertEqual(TransitPalette.fill(for: .metro, line: "a").rgbHex, 0xE0812B)
    }

    // MARK: Every other kind ignores the line

    func testNonMetroKindsUseTheSearchedColours() {
        XCTAssertEqual(TransitPalette.fill(for: .tram, line: "1").rgbHex, 0xD872A5)
        XCTAssertEqual(TransitPalette.fill(for: .trolleybus, line: "1").rgbHex, 0x276F5D)
        XCTAssertEqual(TransitPalette.fill(for: .ferry, line: "1").rgbHex, 0x03AED8)
        XCTAssertEqual(TransitPalette.fill(for: .bus, line: "1").rgbHex, 0x3F72C6)
        XCTAssertEqual(TransitPalette.fill(for: .train, line: "1").rgbHex, 0x7E4587)
    }

    func testNonMetroKindsIgnoreTheLine() {
        for kind in VehicleKind.allCases where kind != .metro {
            XCTAssertEqual(TransitPalette.fill(for: kind, line: "1").rgbHex,
                           TransitPalette.fill(for: kind, line: "A").rgbHex,
                           "\(kind) must not depend on the line")
        }
    }

    func testRecessiveKindsAreMutuallyDistinct() {
        let kinds = VehicleKind.allCases.filter { $0 != .metro }
        let fills = kinds.map { TransitPalette.fill(for: $0, line: "1").rgbHex }
        XCTAssertEqual(Set(fills).count, kinds.count)
    }

    // MARK: The glyph letter stays legible

    /// MapKit draws the glyph white by default, which measures 1.49:1 on the
    /// official metro yellow. Every fill must pair with a glyph at WCAG AA.
    func testEveryGlyphPairingMeetsWCAGAA() {
        var fills = ["A", "B", "C"].map { TransitPalette.style(for: .metro, line: $0) }
        fills += VehicleKind.allCases.filter { $0 != .metro }
            .map { TransitPalette.style(for: $0, line: "1") }
        // The unrecognized-line fallback (amber) renders on the real feed-anomaly
        // path and must be contrast-checked like every other renderable fill.
        fills.append(TransitPalette.style(for: .metro, line: "D"))
        // Retained positions (#31) draw the same line number on a grey bubble —
        // greyed-out is not an excuse for an unreadable glyph.
        fills.append(TransitPalette.style(for: .tram, line: "1", stale: true))

        for style in fills {
            let ratio = Color.contrastRatio(style.fill.relativeLuminance,
                                            style.glyph.relativeLuminance)
            XCTAssertGreaterThanOrEqual(
                ratio, 4.5,
                "fill \(String(format: "%06X", style.fill.rgbHex)) fails AA at \(ratio)")
        }
    }

    func testGlyphPicksTheHigherContrastInk() {
        // Yellow is the case that motivated the rule.
        XCTAssertEqual(TransitPalette.style(for: .metro, line: "B").glyph.rgbHex, 0x000000)
        // Red keeps the conventional white letter.
        XCTAssertEqual(TransitPalette.style(for: .metro, line: "C").glyph.rgbHex, 0xFFFFFF)
    }

    func testRelativeLuminanceEndpoints() {
        XCTAssertEqual(Color.white.relativeLuminance, 1.0, accuracy: 0.001)
        XCTAssertEqual(Color.black.relativeLuminance, 0.0, accuracy: 0.001)
        XCTAssertEqual(Color.contrastRatio(1.0, 0.0), 21.0, accuracy: 0.01)
    }

    /// Anchors the sRGB linearization curve at a midtone. White/black endpoints
    /// are satisfied by any monotone function, so without this a regression that
    /// drops the linearization would leave every other test green.
    func testRelativeLuminanceIsLinearizedNotRaw() {
        XCTAssertEqual(Color(hex: 0x3F72C6).relativeLuminance, 0.1717, accuracy: 0.001)
    }
}
