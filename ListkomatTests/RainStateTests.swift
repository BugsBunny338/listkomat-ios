import XCTest
@testable import Listkomat

/// B2 / listkomat-ios#35: the emoji rain's bookkeeping — the burst math shared
/// with Android, the live-drop cap, pruning, the `recent` decay and Reduce Motion.
final class RainStateTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testBurstSizeMatchesAndroid() {
        // min(10 + recent * 6, 60), recent counted including this tap.
        XCTAssertEqual(RainState.burstSize(recent: 1), 16)
        XCTAssertEqual(RainState.burstSize(recent: 2), 22)
        XCTAssertEqual(RainState.burstSize(recent: 8), 58)
        XCTAssertEqual(RainState.burstSize(recent: 9), 60)
        XCTAssertEqual(RainState.burstSize(recent: 50), 60)
    }

    func testTapsInARowGrowTheBurst() {
        var rain = RainState()
        rain.burst("🦄", now: t0)
        XCTAssertEqual(rain.drops.count, 16)
        XCTAssertEqual(rain.recent, 1)
        rain.burst("🦄", now: t0.addingTimeInterval(0.1))
        XCTAssertEqual(rain.drops.count, 16 + 22)
        XCTAssertEqual(rain.recent, 2)
    }

    func testDropsKeepTheSharedRanges() {
        var rain = RainState()
        for i in 0..<3 { rain.burst("🐸", now: t0.addingTimeInterval(Double(i) * 0.1)) }
        for drop in rain.drops {
            XCTAssertEqual(drop.emoji, "🐸")
            XCTAssertTrue((0.03...0.97).contains(drop.x))
            XCTAssertTrue((0.6...1.3).contains(drop.scale))
            XCTAssertTrue((-220...220).contains(drop.spin))
            XCTAssertTrue((1.6...2.8).contains(drop.duration))
            XCTAssertGreaterThanOrEqual(drop.start, t0)
        }
    }

    func testLiveDropsAreCappedAtOneHundred() {
        var rain = RainState()
        // Ten taps within half a second: 16 + 22 + … well past 300 uncapped.
        for i in 0..<10 { rain.burst("💣", now: t0.addingTimeInterval(Double(i) * 0.05)) }
        XCTAssertEqual(rain.drops.count, RainState.maxDrops)
        // The cap never evicts drops already falling: the first burst (16) is all
        // still there, and the taps past the cap added nothing.
        XCTAssertEqual(rain.drops.prefix(16).filter { $0.start < t0.addingTimeInterval(0.5) }.count, 16)
    }

    func testPastTheCapATapAddsAndRemovesNothing() {
        var rain = RainState()
        for i in 0..<4 { rain.burst("💣", now: t0.addingTimeInterval(Double(i) * 0.1)) } // 16+22+28+34
        let before = rain.drops.map(\.start)
        rain.burst("🐸", now: t0.addingTimeInterval(0.5))
        XCTAssertEqual(rain.drops.map(\.start), before)
    }

    func testAtTheCapATapOnlyFillsTheRoomLeft() {
        var rain = RainState()
        rain.burst("💣", now: t0)                              // 16
        for i in 1..<4 { rain.burst("💣", now: t0.addingTimeInterval(Double(i) * 0.1)) } // +22 +28 +34 = 100
        XCTAssertEqual(rain.drops.count, 100)
        // Once the first burst has landed, a tap refills only what it left.
        rain.burst("🐸", now: t0.addingTimeInterval(3.5))
        let room = 100 - rain.drops.filter { $0.emoji == "💣" }.count
        XCTAssertEqual(rain.drops.filter { $0.emoji == "🐸" }.count,
                       min(RainState.burstSize(recent: rain.recent), room))
        XCTAssertLessThanOrEqual(rain.drops.count, RainState.maxDrops)
        XCTAssertGreaterThan(rain.drops.filter { $0.emoji == "🐸" }.count, 0)
    }

    func testFinishedDropsArePruned() {
        var rain = RainState()
        rain.burst("🐰", now: t0)
        rain.prune(now: t0.addingTimeInterval(1))
        XCTAssertEqual(rain.drops.count, 16, "nothing has finished after 1 s")
        // Every drop ends by 0.5 s stagger + 2.8 s fall.
        rain.prune(now: t0.addingTimeInterval(3.31))
        XCTAssertTrue(rain.drops.isEmpty)
    }

    func testABurstPrunesFinishedDropsFirst() {
        var rain = RainState()
        rain.burst("🐻", now: t0)
        rain.decay()
        rain.burst("🐻", now: t0.addingTimeInterval(10))
        XCTAssertEqual(rain.drops.count, 16, "the first burst is gone, the second is a fresh 16")
        XCTAssertTrue(rain.drops.allSatisfy { $0.start >= self.t0.addingTimeInterval(10) })
    }

    func testRecentDecaysAndFloorsAtZero() {
        var rain = RainState()
        rain.burst("🐌", now: t0)
        rain.burst("🐌", now: t0)
        rain.decay()
        XCTAssertEqual(rain.recent, 1)
        rain.decay()
        rain.decay()
        XCTAssertEqual(rain.recent, 0)
        // After the decay the next tap is a small burst again.
        rain.prune(now: t0.addingTimeInterval(10))
        rain.burst("🐌", now: t0.addingTimeInterval(10))
        XCTAssertEqual(rain.drops.count, 16)
    }

    func testReduceMotionSkipsTheRain() {
        var rain = RainState()
        XCTAssertFalse(rain.burst("🐉", now: t0, reduceMotion: true))
        XCTAssertTrue(rain.drops.isEmpty)
        XCTAssertEqual(rain.recent, 0, "no tap is counted, so nothing is left to decay")
    }

    func testLowPowerModeIsADrizzle() {
        var rain = RainState()
        for i in 0..<5 { rain.burst("🐐", now: t0.addingTimeInterval(Double(i) * 0.1), lowPower: true) }
        XCTAssertEqual(rain.drops.count, 5 * RainState.lowPowerBurst)
    }

    func testEmojisAreDistinctInOrder() {
        var rain = RainState()
        rain.burst("🦄", now: t0)
        rain.burst("🍺", now: t0)
        XCTAssertEqual(rain.emojis, ["🦄", "🍺"])
    }
}
