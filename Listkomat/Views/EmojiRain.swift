import SwiftUI

/// One falling emoji. Its position is derived from `start` + elapsed time inside
/// a Canvas, so spawning more drops never interrupts the ones already falling.
struct RainDrop: Identifiable {
    let id = UUID()
    let emoji: String
    let x: CGFloat        // 0...1 fraction of screen width
    let scale: CGFloat
    let spin: Double
    let duration: Double
    let start: Date       // when this drop begins falling (now + a small stagger)

    static func burst(_ emoji: String, count: Int, now: Date) -> [RainDrop] {
        (0..<count).map { _ in
            RainDrop(
                emoji: emoji,
                x: .random(in: 0.03...0.97),
                scale: .random(in: 0.6...1.3),
                spin: .random(in: -220...220),
                duration: .random(in: 1.6...2.8),
                start: now.addingTimeInterval(.random(in: 0...0.5))
            )
        }
    }
}

/// Bump `trigger` (an incrementing nonce) to drop a burst. The emoji is resolved
/// here from the live `themeId` at burst time, so it's always the *current*
/// mascot — even if the toolbar button that bumped the nonce captured a stale
/// value. Drops live in this layer's own state and are drawn in a Canvas, so a
/// new tap never re-runs the parent view's body or interrupts drops already in
/// flight. Rapid taps pile up for a heavier downpour.
struct RainLayer: View {
    let trigger: Int
    @AppStorage("themeId") private var themeId = AppTheme.default.id
    @State private var drops: [RainDrop] = []
    @State private var recent = 0

    var body: some View {
        Group {
            if drops.isEmpty {
                Color.clear   // no animation timer while idle
            } else {
                TimelineView(.animation) { timeline in
                    Canvas { context, size in
                        let now = timeline.date
                        for drop in drops {
                            let p = now.timeIntervalSince(drop.start) / drop.duration
                            guard p >= 0, p <= 1 else { continue }
                            let eased = p * p   // gentle gravity-like acceleration
                            let y = -60 + (size.height + 120) * eased
                            var ctx = context
                            ctx.translateBy(x: drop.x * size.width, y: y)
                            ctx.rotate(by: .degrees(drop.spin * p))
                            ctx.scaleBy(x: drop.scale, y: drop.scale)
                            ctx.draw(ctx.resolve(Text(drop.emoji).font(.system(size: 36))),
                                     at: .zero)
                        }
                    }
                }
            }
        }
        .ignoresSafeArea()   // fall from the very top, above the Dynamic Island
        .allowsHitTesting(false)
        .onChange(of: trigger) { _ in addBurst() }
    }

    private func addBurst() {
        guard trigger > 0, let mascot = AppTheme.resolve(themeId).mascot else { return }
        recent += 1
        let count = min(10 + recent * 6, 60)
        drops.append(contentsOf: RainDrop.burst(mascot, count: count, now: Date()))
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
            let cutoff = Date()
            drops.removeAll { $0.start.addingTimeInterval($0.duration) < cutoff }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            if recent > 0 { recent -= 1 }
        }
    }
}
