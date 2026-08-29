import SwiftUI

/// Fill and glyph colour for one live-map marker.
struct MarkerStyle: Equatable {
    let fill: Color
    let glyph: Color
}

/// Single source of truth for live-map marker colours.
///
/// Prague's metro lines carry conventional colours riders navigate by — A green,
/// B yellow, C red — so metro is coloured per line. Every other kind gets one
/// lower-chroma colour, chosen so nothing competes with a metro line.
///
/// The values were picked by constrained search against a contrast and
/// colour-blindness validator, not by eye: hand-designed candidates scored 2.7–5.5
/// on the worst-pair CVD test where this set scores 7.2, and the set clears the
/// normal-vision floor at ΔE 15.4. Metro A green vs C red is inherently
/// red-green (ΔE 5.9 under deuteranopia) and cannot be fixed while keeping the
/// official colours — the always-present line letter is the mitigation.
///
/// See docs/plans/2026-08-29-listkomat-metro-line-colours-design.md before editing.
enum TransitPalette {

    // Official Prague metro line colours.
    static let metroA = Color(hex: 0x00A05A)   // green
    static let metroB = Color(hex: 0xFFCE00)   // yellow
    static let metroC = Color(hex: 0xE1252B)   // red

    /// Metro on a line we don't recognize. Deliberately the pre-2.4 amber, so a
    /// feed anomaly degrades to the old appearance rather than to a wrong line colour.
    static let metroUnknown = Color(hex: 0xE0812B)

    /// Marker fill. Only `.metro` consults `line`.
    static func fill(for kind: VehicleKind, line: String) -> Color {
        switch kind {
        case .metro:
            switch line {
            case "A": return metroA
            case "B": return metroB
            case "C": return metroC
            default:  return metroUnknown
            }
        case .tram:       return Color(hex: 0xD872A5)   // pink
        case .trolleybus: return Color(hex: 0x276F5D)   // deep teal
        case .ferry:      return Color(hex: 0x03AED8)   // cyan — reads as water
        case .bus:        return Color(hex: 0x3F72C6)   // blue
        case .train:      return Color(hex: 0x7E4587)   // violet
        }
    }

    /// Fill plus the ink the line letter should be drawn in.
    static func style(for kind: VehicleKind, line: String) -> MarkerStyle {
        let fill = fill(for: kind, line: line)
        return MarkerStyle(fill: fill, glyph: fill.readableGlyph)
    }
}

extension Color {
    /// Black or white — whichever has more contrast against this colour.
    ///
    /// MapKit draws marker glyphs white by default, which measures 1.49:1 on the
    /// official metro yellow and is effectively unreadable.
    var readableGlyph: Color {
        let l = relativeLuminance
        return Self.contrastRatio(l, 1.0) >= Self.contrastRatio(l, 0.0) ? .white : .black
    }

    /// WCAG 2.1 relative luminance. Returns 0 for any colour UIKit can't express
    /// as RGB, which makes `readableGlyph` fall back to a white glyph.
    var relativeLuminance: Double {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a) else { return 0 }
        func channel(_ v: CGFloat) -> Double {
            let v = Double(v)
            return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)
    }

    /// WCAG contrast ratio between two relative luminances.
    static func contrastRatio(_ l1: Double, _ l2: Double) -> Double {
        let hi = max(l1, l2), lo = min(l1, l2)
        return (hi + 0.05) / (lo + 0.05)
    }
}
