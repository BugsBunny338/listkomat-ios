import SwiftUI
import UIKit

/// One falling emoji. Its position is derived from `start` + elapsed time inside
/// a Canvas, so spawning more drops never interrupts the ones already falling.
struct RainDrop {
    let emoji: String
    let x: CGFloat        // 0...1 fraction of screen width
    let scale: CGFloat
    let spin: Double
    let duration: Double
    let start: Date       // when this drop begins falling (now + a small stagger)

    var end: Date { start.addingTimeInterval(duration) }

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

/// The rain's bookkeeping, apart from SwiftUI so it can be unit tested (Android
/// has the same `RainState`). The burst math is shared with Android and must stay
/// identical: `min(10 + recent * 6, 60)` drops per tap, where `recent` counts the
/// taps of the last two seconds.
struct RainState {
    private(set) var drops: [RainDrop] = []
    /// Taps in the last ~2 s; each tap is taken back by `decay()` two seconds later.
    private(set) var recent = 0

    /// Live drops never exceed this, however fast the mascot is tapped: without
    /// it, ten taps in two seconds kept 300+ drops in flight. At the cap a tap only
    /// adds what fits; drops already falling are never removed (evicting the
    /// oldest wiped out the visible rain and left only drops still above the top
    /// edge while the mascot was being tapped).
    static let maxDrops = 100
    static let maxBurst = 60
    /// Low Power Mode keeps the egg but makes it a drizzle (Android: power save).
    static let lowPowerBurst = 15
    /// How long after a tap `decay()` runs, and after a burst the finished drops
    /// are pruned (longer than any drop's stagger + fall).
    static let decayDelay: TimeInterval = 2
    static let pruneDelay: TimeInterval = 4

    static func burstSize(recent: Int) -> Int { min(10 + recent * 6, maxBurst) }

    /// A tap. Returns false (and changes nothing) when the rain is off: with
    /// Reduce Motion there is no rain at all, so there is nothing to decay later.
    @discardableResult
    mutating func burst(_ emoji: String, now: Date, reduceMotion: Bool = false,
                        lowPower: Bool = false) -> Bool {
        guard !reduceMotion else { return false }
        prune(now: now)
        recent += 1
        var count = Self.burstSize(recent: recent)
        if lowPower { count = min(count, Self.lowPowerBurst) }
        count = min(count, max(0, Self.maxDrops - drops.count))
        drops.append(contentsOf: RainDrop.burst(emoji, count: count, now: now))
        return true
    }

    /// Drops whose fall has finished are gone for good.
    mutating func prune(now: Date) {
        drops.removeAll { $0.end < now }
    }

    /// Two seconds after a tap, it stops counting toward the next burst's size.
    mutating func decay() {
        if recent > 0 { recent -= 1 }
    }

    /// The distinct emoji in flight (in practice one: the current mascot, or two
    /// right after a theme switch), each resolved once per frame.
    var emojis: [String] {
        var seen = Set<String>()
        return drops.compactMap { seen.insert($0.emoji).inserted ? $0.emoji : nil }
    }
}

/// The mascot button bumps `nonce`; only `RainLayer` observes it, so a tap
/// re-renders the rain and nothing else.
final class RainTrigger: ObservableObject {
    @Published var nonce = 0
}

/// Each emoji pre-rendered once to a bitmap (Android's GlyphCache), at the
/// largest drop scale so drops only ever shrink. Drawing an image needs no text
/// layout once an emoji is cached (the tap warms it). Main thread only.
enum RainGlyphs {
    static let rasterScale: CGFloat = 1.3
    private static var cache: [String: Image] = [:]

    static func image(_ emoji: String, size: CGFloat) -> Image {
        let key = "\(emoji)@\(size)"
        if let hit = cache[key] { return hit }
        let font = UIFont.systemFont(ofSize: size * rasterScale)
        let text = NSAttributedString(string: emoji, attributes: [.font: font])
        let bounds = text.size()
        // Whole points plus a 2 pt margin, so artwork that touches its line box
        // keeps a soft edge when rotated (Android pads its bitmap the same way).
        let pad: CGFloat = 2
        let canvas = CGSize(width: ceil(bounds.width) + 2 * pad, height: ceil(bounds.height) + 2 * pad)
        let image = UIGraphicsImageRenderer(size: canvas).image { _ in
            text.draw(at: CGPoint(x: (canvas.width - bounds.width) / 2,
                                  y: (canvas.height - bounds.height) / 2))
        }
        let result = Image(uiImage: image)
        cache[key] = result
        return result
    }
}

/// Bump `trigger.nonce` to drop a burst. The emoji is resolved
/// here from the live `themeId` at burst time, so it's always the *current*
/// mascot — even if the toolbar button that bumped the nonce captured a stale
/// value. Drops live in this layer's own state and are drawn in a Canvas, so a
/// new tap never re-runs the parent view's body or interrupts drops already in
/// flight. Rapid taps pile up for a heavier downpour, capped (`RainState`).
struct RainLayer: View {
    @ObservedObject var trigger: RainTrigger
    @AppStorage("themeId") private var themeId = AppTheme.default.id
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var rain = RainState()

    /// The glyph size every drop is drawn at before its own scale (as Android).
    private static let glyphSize: CGFloat = 36

    var body: some View {
        Group {
            if rain.drops.isEmpty {
                Color.clear   // no animation timer while idle
            } else {
                // No minimumInterval: without CADisableMinimumFrameDurationOnPhone
                // in Info.plist the app already animates at ≤ 60 fps on ProMotion,
                // and a 1/60 floor can drop the odd frame on a 60 Hz display.
                TimelineView(.animation) { timeline in
                    let drops = rain.drops
                    // Each glyph is a cached bitmap, resolved once per frame and
                    // drawn per drop. Resolving a Text per drop per frame was the
                    // stutter (listkomat-ios#35).
                    let glyphs = Dictionary(uniqueKeysWithValues: rain.emojis.map {
                        ($0, RainGlyphs.image($0, size: Self.glyphSize))
                    })
                    Canvas { context, size in
                        let now = timeline.date
                        var resolved: [String: GraphicsContext.ResolvedImage] = [:]
                        let shrink = 1 / RainGlyphs.rasterScale
                        for drop in drops {
                            let p = now.timeIntervalSince(drop.start) / drop.duration
                            guard p >= 0, p <= 1 else { continue }
                            guard let image = resolved[drop.emoji]
                                ?? glyphs[drop.emoji].map({ context.resolve($0) })
                            else { continue }
                            resolved[drop.emoji] = image
                            let eased = p * p   // gentle gravity-like acceleration
                            let y = -60 + (size.height + 120) * eased
                            var ctx = context
                            ctx.translateBy(x: drop.x * size.width, y: y)
                            ctx.rotate(by: .degrees(drop.spin * p))
                            ctx.scaleBy(x: drop.scale * shrink, y: drop.scale * shrink)
                            ctx.draw(image, at: .zero)   // centred, like the Text was
                        }
                    }
                }
            }
        }
        .ignoresSafeArea()   // fall from the very top, above the Dynamic Island
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onChange(of: trigger.nonce) { _ in addBurst() }
    }

    private func addBurst() {
        // onChange only fires on a real change (a tap). Resolve the current mascot
        // from @AppStorage, never from whatever the toolbar button captured.
        guard let mascot = AppTheme.resolve(themeId).mascot else { return }
        // Rasterise the glyph now (once per emoji), not inside the next frame.
        _ = RainGlyphs.image(mascot, size: Self.glyphSize)
        // Read once per tap, never per frame.
        guard rain.burst(mascot, now: Date(), reduceMotion: reduceMotion,
                         lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled)
        else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + RainState.pruneDelay) {
            rain.prune(now: Date())
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + RainState.decayDelay) {
            rain.decay()
        }
    }
}
