import SwiftUI

/// One falling emoji in the mascot-rain easter egg.
/// All drops render at this one font size; per-drop size variety comes from
/// `scaleEffect` (a GPU transform) so the emoji glyph is only rasterized once —
/// avoids a frame hitch when a burst spawns.
private let dropFontSize: CGFloat = 36

struct RainDrop: Identifiable {
    let id = UUID()
    let emoji: String
    let x: CGFloat        // 0...1 fraction of screen width
    let scale: CGFloat    // applied via scaleEffect, not font size
    let duration: Double
    let delay: Double
    let spin: Double

    /// A burst of `count` randomized drops of one emoji.
    static func burst(_ emoji: String, count: Int) -> [RainDrop] {
        (0..<count).map { _ in
            RainDrop(
                emoji: emoji,
                x: CGFloat.random(in: 0.03...0.97),
                scale: CGFloat.random(in: 0.6...1.3),
                duration: Double.random(in: 1.4...2.6),
                delay: Double.random(in: 0...0.5),
                spin: Double.random(in: -220...220)
            )
        }
    }
}

private struct FallingEmoji: View {
    let drop: RainDrop
    let size: CGSize
    @State private var fall = false

    var body: some View {
        Text(drop.emoji)
            .font(.system(size: dropFontSize))
            .scaleEffect(drop.scale)
            .rotationEffect(.degrees(fall ? drop.spin : 0))
            .position(x: drop.x * size.width, y: fall ? size.height + 60 : -60)
            .onAppear {
                withAnimation(.easeIn(duration: drop.duration).delay(drop.delay)) {
                    fall = true
                }
            }
    }
}

/// Full-screen, non-interactive overlay that renders the current drops falling.
struct EmojiRainOverlay: View {
    let drops: [RainDrop]

    var body: some View {
        GeometryReader { geo in
            ZStack {
                ForEach(drops) { drop in
                    FallingEmoji(drop: drop, size: geo.size)
                }
            }
        }
        .allowsHitTesting(false)
    }
}
