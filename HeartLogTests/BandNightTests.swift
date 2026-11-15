import XCTest

/// Synthetic records only. No real person's data.
final class BandNightTests: XCTestCase {
    /// A v18 inner record laid out like the band's.
    private func v18(t: UInt32, hr: UInt8, rr: [Int16], g: [Float], steps: UInt16, state: UInt8) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: 112)
        b[0] = 0x2F; b[1] = 18
        func put32(_ o: Int, _ v: UInt32) { for i in 0..<4 { b[o + i] = UInt8((v >> (8 * UInt32(i))) & 0xFF) } }
        put32(3, 99)
        put32(7, t)
        b[14] = hr
        b[15] = UInt8(rr.count)
        for (i, v) in rr.enumerated() { let u = UInt16(bitPattern: v); b[16 + 2 * i] = UInt8(u & 0xFF); b[17 + 2 * i] = UInt8(u >> 8) }
        put32(33, Float(0.01).bitPattern)
        for (i, v) in g.enumerated() { put32(37 + 4 * i, v.bitPattern) }
        b[49] = UInt8(steps & 0xFF); b[50] = UInt8(steps >> 8)
        b[55] = 1
        b[73] = state << 4 | 0x01
        return b
    }

    func testDecodesV18() throws {
        let s = try XCTUnwrap(BandSecond.decode(v18(t: 1_800_000_000, hr: 58, rr: [1010, 1030, 5000], g: [0.1, -0.2, 0.97], steps: 4321, state: 2)))
        XCTAssertEqual(s.t, 1_800_000_000)
        XCTAssertEqual(s.hr, 58)
        XCTAssertEqual(s.rr, [1010, 1030], "5000 ms is not a real beat")
        XCTAssertEqual(s.gravity?.count, 3)
        XCTAssertEqual(Double(s.gravity?[2] ?? 0), 0.97, accuracy: 1e-6)
        XCTAssertEqual(s.steps, 4321)
        XCTAssertEqual(s.activity, 1)
        XCTAssertEqual(s.sleepState, 2)
    }

    func testRejectsOtherRecords() {
        var other = v18(t: 1, hr: 60, rr: [], g: [0, 0, 1], steps: 0, state: 0)
        other[1] = 20
        XCTAssertNil(BandSecond.decode(other))
        XCTAssertNil(BandSecond.decode(Array(v18(t: 1, hr: 60, rr: [], g: [0, 0, 1], steps: 0, state: 0).prefix(80))))
    }

    func testBadHeartRateKeepsTheRest() throws {
        let s = try XCTUnwrap(BandSecond.decode(v18(t: 5, hr: 250, rr: [900], g: [0, 0, 1], steps: 7, state: 1)))
        XCTAssertEqual(s.hr, 0)
        XCTAssertEqual(s.rr, [900])
        XCTAssertEqual(s.steps, 7)
    }

    func testStorageRoundTrip() {
        let a = BandSecond(t: 1_800_000_123, hr: 61, rr: [980, 1001, 1012], gravity: [0.5, -0.25, 0.75], steps: 65000, activity: 2, sleepState: 3)
        let b = BandSecond(t: 1_800_000_124, hr: 0, rr: [], gravity: nil, steps: 1, activity: 0, sleepState: 0)
        let bytes = a.encoded() + b.encoded()
        XCTAssertEqual(bytes.count, 2 * BandSecond.size)
        XCTAssertEqual(BandSecond.decodeStored(bytes[0..<36]), a)
        XCTAssertEqual(BandSecond.decodeStored(bytes[36..<72]), b)
    }

    func testMarkers() {
        XCTAssertEqual(BandHistoryMarker([0x31, 0, 2, 0]), .end)
        XCTAssertEqual(BandHistoryMarker([0x31, 0, 3]), .complete)
        XCTAssertNil(BandHistoryMarker([0x2F, 0, 2]))
    }

    func testTidySortsAndDedupes() {
        let s = { (t: Int64, hr: Int) in BandSecond(t: t, hr: hr, rr: [], gravity: nil, steps: 0, activity: 0, sleepState: 0) }
        XCTAssertEqual(BandNight.tidy([s(3, 1), s(1, 1), s(3, 2)]).map(\.hr), [1, 2])
        XCTAssertEqual(BandNight.tidy([s(3, 1), s(1, 1), s(3, 2)]).map(\.t), [1, 3])
    }

    // MARK: Night

    /// A synthetic night: awake 20 min, asleep 4 h with a 15-minute wake-up
    /// (fast heart, moving) in the middle, awake 20 min. One record a second.
    private func night(start: Int64 = 1_800_000_000) -> [BandSecond] {
        var rng = SystemRandomNumberGenerator()
        var out: [BandSecond] = []
        let total = (20 + 240 + 20) * 60
        for i in 0..<total {
            let min = i / 60
            let awake = min < 20 || min >= 260 || (min >= 130 && min < 145)
            let hr = awake ? 86 + Int.random(in: -3...3, using: &rng) : 56 + Int.random(in: -2...2, using: &rng)
            let base = 60000.0 / Double(hr)
            let rr = [Int(base + Double.random(in: -25...25, using: &rng))]
            let wobble: Float = awake ? Float.random(in: -0.3...0.3, using: &rng) : 0
            let state = min < 15 ? 0 : (min < 20 ? 1 : (min >= 260 ? 3 : (awake ? 0 : 2)))
            out.append(BandSecond(t: start + Int64(i), hr: hr, rr: rr, gravity: [0.1 + wobble, 0.2, 0.97 - wobble], steps: 0, activity: 0, sleepState: state))
        }
        return out
    }

    func testWindowFollowsTheBandsState() throws {
        let secs = night()
        let w = try XCTUnwrap(BandNight.window(secs))
        // Starts at the 15-minute "still", runs through the mid-night wake (under 30 min), ends at minute 260.
        let base: Int64 = 1_800_000_000 - 1_800_000_000 % 60
        let wantStart: Int64 = base + 15 * 60
        let wantEnd: Int64 = base + 260 * 60
        XCTAssertEqual(w.start, wantStart)
        XCTAssertLessThanOrEqual(abs(w.end - wantEnd), 120)
    }

    func testNoWindowWithoutSleep() {
        let awake = (0..<7200).map { BandSecond(t: Int64($0), hr: 80, rr: [750], gravity: [0, 0, 1], steps: 0, activity: 0, sleepState: 0) }
        XCTAssertNil(BandNight.window(awake))
    }

    func testInputFillsShortGapsAndSplitsLongOnes() {
        var secs: [BandSecond] = []
        let mk = { (t: Int64) in BandSecond(t: t, hr: 60, rr: [1000], gravity: [0, 0, 1], steps: 0, activity: 0, sleepState: 2) }
        for t in 0..<95 { secs.append(mk(Int64(t))) }         // 95 s, then a 5 s gap
        for t in 100..<200 { secs.append(mk(Int64(t))) }      // continues to 200
        for t in 1000..<1065 { secs.append(mk(Int64(t))) }    // after a long gap: 65 s
        let inp = BandNight.input(secs, from: 0, to: 2000)
        XCTAssertEqual(inp.hr.count, 180 + 60, "first run 200 s trimmed to 180, second 65 trimmed to 60")
        XCTAssertEqual(inp.runStarts, [180])
        XCTAssertEqual(inp.hr[96], 0, "gap second filled with no reading")
        XCTAssertEqual(inp.tsMs[180], 1_000_000)
        XCTAssertTrue(inp.rrTsMs.allSatisfy { $0 < 180_000 || ($0 >= 1_000_000 && $0 < 1_060_000) })
        XCTAssertEqual(inp.rrMs.count, inp.rrTsMs.count)
    }

    func testStagesASyntheticNight() throws {
        let secs = night()
        let stages = try XCTUnwrap(BandNight.stages(secs))
        let mins = Dictionary(grouping: stages, by: \.kind).mapValues { $0.reduce(0) { $0 + $1.minutes } }
        let asleep = (mins[.light] ?? 0) + (mins[.deep] ?? 0) + (mins[.rem] ?? 0)
        XCTAssertGreaterThan(asleep, 190, "most of the 4 hours reads as sleep")
        // The mid-night wake-up (minutes 130-145 from the start) shows as wake.
        let wakeUpMs: Int64 = (1_800_000_000 + 137 * 60) * 1000
        let block = stages.first { $0.start <= wakeUpMs && $0.end > wakeUpMs }
        XCTAssertEqual(block?.kind, .wake)
        // Blocks are contiguous and in order.
        for i in 1..<stages.count { XCTAssertGreaterThanOrEqual(stages[i].start, stages[i - 1].end) }
    }

    func testNoHeartRateMeansNoStages() {
        let secs = night().map { s -> BandSecond in var c = s; c.hr = 0; c.rr = []; return c }
        XCTAssertNil(BandNight.stages(secs))
    }

    // MARK: Stager pieces

    func testFastPeriodogramMatchesPlainLombScargle() {
        var t: [Double] = [], y: [Double] = []
        var x = 0.0
        for i in 0..<150 { let v = 1000 + 40 * sin(Double(i) * 0.9) + 15 * cos(Double(i) * 0.2); x += v / 1000; t.append(x); y.append(v) }
        let grid = (0..<240).map { 0.01 + (0.4 - 0.01) / 239 * Double($0) }
        let slow = CardioStager.lombScargle(t, y, grid)!
        let fast = BreathingMath.periodogram(t, y, lo: 0.01, hi: 0.4, count: 240)
        for i in grid.indices { XCTAssertEqual(fast[i], slow[i], accuracy: max(1e-6, slow[i] * 1e-6)) }
    }

    func testWebsterBridgesShortWakeOnly() {
        typealias S = CardioStager.Stage
        // 30 epochs (15 min) sleep, 2 epochs (1 min) wake, 30 sleep: bridged.
        var a: [S] = Array(repeating: .nrem, count: 30) + [.wake, .wake] + Array(repeating: .nrem, count: 30)
        CardioStager.websterRescore(&a)
        XCTAssertFalse(a.contains(.wake))
        // 20 epochs (10 min) of wake: kept.
        var b: [S] = Array(repeating: .nrem, count: 30) + Array(repeating: .wake, count: 20) + Array(repeating: .nrem, count: 30)
        CardioStager.websterRescore(&b)
        XCTAssertEqual(b.filter { $0 == .wake }.count, 20)
    }

    func testConsolidateFoldsShortBouts() {
        typealias S = CardioStager.Stage
        var a: [S] = Array(repeating: .nrem, count: 20) + Array(repeating: .rem, count: 4) + Array(repeating: .nrem, count: 20)
        CardioStager.consolidate(&a)
        XCTAssertEqual(a, Array(repeating: .nrem, count: 44))
    }

    func testStatsMatchOpenStrapDefinitions() {
        XCTAssertEqual(CardioStager.median([1, 2, 3, 4]), 2.5)
        XCTAssertEqual(CardioStager.stddev([2, 4, 4, 4, 5, 5, 7, 9])!, 2.138, accuracy: 0.001)
        XCTAssertEqual(CardioStager.mad([1, 1, 2, 2, 4, 6, 9])!, 1.4826, accuracy: 1e-9)
        XCTAssertEqual(CardioStager.percentileSorted([10, 20, 30, 40], 25)!, 17.5, accuracy: 1e-9)
    }

    // MARK: Steps

    private func counter(_ pairs: [(Int64, Int)]) -> [BandSecond] {
        pairs.map { BandSecond(t: $0.0, hr: 70, rr: [], gravity: nil, steps: $0.1, activity: 1, sleepState: 0) }
    }

    func testStepsCountRisesAcrossTheWrap() {
        XCTAssertEqual(BandNight.steps(counter([(0, 65_530), (1, 65_532), (2, 65_534), (3, 0), (4, 3)])), 9)
    }

    func testStepsSkipResetsAndLongGaps() {
        // A drop (counter reset) is skipped, not read as ~65k steps.
        XCTAssertEqual(BandNight.steps(counter([(0, 500), (1, 502), (2, 10), (3, 12)])), 4)
        // A rise too big for the time between records is skipped.
        XCTAssertEqual(BandNight.steps(counter([(0, 0), (1, 400)])), 0)
        // Across a 20-minute gap, a plausible rise still counts.
        XCTAssertEqual(BandNight.steps(counter([(0, 0), (1200, 900)])), 900)
        // Over 3 hours apart: skipped.
        XCTAssertEqual(BandNight.steps(counter([(0, 0), (4 * 3600, 900)])), 0)
    }
}
