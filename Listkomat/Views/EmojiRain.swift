import SwiftUI

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
    /// it, ten taps in two seconds kept 300+ drops in flight.
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
        drops.append(contentsOf: RainDrop.burst(emoji, count: count, now: now))
        if drops.count > Self.maxDrops { drops.removeFirst(drops.count - Self.maxDrops) }
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

/// Bump `trigger` (an incrementing nonce) to drop a burst. The emoji is resolved
/// here from the live `themeId` at burst time, so it's always the *current*
/// mascot — even if the toolbar button that bumped the nonce captured a stale
/// value. Drops live in this layer's own state and are drawn in a Canvas, so a
/// new tap never re-runs the parent view's body or interrupts drops already in
/// flight. Rapid taps pile up for a heavier downpour, capped (`RainState`).
struct RainLayer: View {
    let trigger: Int
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
                    // The glyph is a Canvas symbol: laid out and rendered once,
                    // then drawn per drop. Resolving a Text per drop per frame was
                    // the stutter (listkomat-ios#35).
                    Canvas(rendersAsynchronously: true) { context, size in
                        let now = timeline.date
                        var symbols: [String: GraphicsContext.ResolvedSymbol] = [:]
                        for drop in drops {
                            let p = now.timeIntervalSince(drop.start) / drop.duration
                            guard p >= 0, p <= 1 else { continue }
                            guard let symbol = symbols[drop.emoji] ?? context.resolveSymbol(id: drop.emoji)
                            else { continue }
                            symbols[drop.emoji] = symbol
                            let eased = p * p   // gentle gravity-like acceleration
                            let y = -60 + (size.height + 120) * eased
                            var ctx = context
                            ctx.translateBy(x: drop.x * size.width, y: y)
                            ctx.rotate(by: .degrees(drop.spin * p))
                            ctx.scaleBy(x: drop.scale, y: drop.scale)
                            ctx.draw(symbol, at: .zero)
                        }
                    } symbols: {
                        ForEach(rain.emojis, id: \.self) { emoji in
                            Text(emoji).font(.system(size: Self.glyphSize)).tag(emoji)
                        }
                    }
                }
            }
        }
        .ignoresSafeArea()   // fall from the very top, above the Dynamic Island
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onChange(of: trigger) { _ in addBurst() }
    }

    private func addBurst() {
        // No `trigger > 0` guard: onChange only fires on a real change (a tap), and
        // the closure captures a one-step-stale `trigger`, so guarding on it ate the
        // very first tap. Resolve the current mascot from @AppStorage instead.
        guard let mascot = AppTheme.resolve(themeId).mascot else { return }
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
