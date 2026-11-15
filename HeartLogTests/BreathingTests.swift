import XCTest

/// Synthetic beats only. No real person's data.
final class BreathingTests: XCTestCase {
    /// Beats whose intervals swing at `brpm` breaths a minute around `nn` ms.
    private func beats(brpm: Double, nn: Double = 1000, swing: Double = 40, noise: Double = 15,
                       minutes: Double = 20, seed: UInt64 = 1) -> [BreathingMath.Beat] {
        var rng = Seeded(seed)
        var t = 0.0
        var out: [BreathingMath.Beat] = []
        while t < minutes * 60 {
            let v = nn + swing * sin(2 * .pi * brpm / 60 * t) + noise * rng.gauss()
            t += v / 1000
            out.append(.init(t: t, nn: v))
        }
        return out
    }

    func testFindsTheBreathingRate() throws {
        for rate in [12.0, 15.0, 18.0, 22.0] {
            let e = try XCTUnwrap(BreathingMath.rate(beats(brpm: rate), artifact: 0), "rate \(rate)")
            XCTAssertEqual(e.brpm, rate, accuracy: 0.5, "rate \(rate)")
            XCTAssertGreaterThanOrEqual(e.usable, 5)
        }
    }

    func testNoRhythmGivesNothing() {
        XCTAssertNil(BreathingMath.rate(beats(brpm: 15, swing: 0, noise: 30), artifact: 0))
    }

    func testTooManyBadBeatsGivesNothing() {
        XCTAssertNil(BreathingMath.rate(beats(brpm: 15), artifact: 0.4))
    }

    func testVerySlowHeartRateIsWithheld() {
        // At 43 bpm, beat timing can't separate a normal rate from an alias.
        XCTAssertNil(BreathingMath.rate(beats(brpm: 15, nn: 1400), artifact: 0))
    }

    func testTooShortGivesNothing() {
        XCTAssertNil(BreathingMath.rate(beats(brpm: 15, minutes: 1.5), artifact: 0))
    }

    func testBeatsFromSamplesDropJumpsAndCountThem() {
        // One sample a second with one interval each; one missed beat (2000 ms) and one impossible value.
        var samples: [Sample] = []
        for i in 0..<60 { samples.append(Sample(t: Int64(i) * 1000, hr: 60, rr: [1000])) }
        samples[30] = Sample(t: 30_000, hr: 60, rr: [1990])
        samples[40] = Sample(t: 40_000, hr: 60, rr: [150])
        let b = BreathingMath.beats(samples)
        XCTAssertEqual(b.beats.count, 58)
        XCTAssertEqual(b.artifact, 2.0 / 60, accuracy: 1e-9)
        XCTAssertEqual(b.beats.first?.t ?? -1, 0, accuracy: 1e-9)
    }

    func testSeveralIntervalsInOneSampleGetTheirOwnTimes() {
        let b = BreathingMath.beats([Sample(t: 10_000, hr: 60, rr: [900, 1000, 1100])])
        XCTAssertEqual(b.beats.count, 3)
        for (got, want) in zip(b.beats.map(\.t), [7.9, 8.9, 10.0]) { XCTAssertEqual(got, want, accuracy: 1e-9) }
    }

    func testSamplesRoundTripToARate() throws {
        // Samples shaped like the band's broadcast: one per second, carrying the beats that ended in it.
        let raw = beats(brpm: 16)
        var samples: [Sample] = []
        var i = 0
        var second: Int64 = 1
        while i < raw.count {
            var rr: [Int] = []
            while i < raw.count, raw[i].t <= Double(second) { rr.append(Int(raw[i].nn.rounded())); i += 1 }
            samples.append(Sample(t: second * 1000, hr: 60, rr: rr))
            second += 1
        }
        let e = try XCTUnwrap(BreathingMath.night(samples))
        XCTAssertEqual(e.brpm, 16, accuracy: 0.6)
    }

    func testWhoopBreathingFromOpenStrapCopy() {
        let daily = Data("""
        date,resting_hr,hrv,resp_rate,steps,worn_min,source
        2026-01-01,60,30,15.54,,,whoop_export
        2026-01-02,,,15.2,1200,600,band
        """.utf8)
        let r = OpenStrapImport.parse(files: ["openstrap_daily_1.csv": daily])
        XCTAssertEqual(r.whoopBreathing, ["2026-01-01": 15.54])
        XCTAssertEqual(Set(r.data.days.keys), ["2026-01-02"])
    }

    func testFillBreathingOnlyFillsGaps() {
        var h = HistoryData()
        h.days["2026-01-01"] = DayRecord(day: "2026-01-01", source: "whoop")
        var has = DayRecord(day: "2026-01-02", source: "whoop")
        has.respRate = 16.0
        h.days["2026-01-02"] = has
        let (out, n) = HistoryImport.fillBreathing(["2026-01-01": 15.54, "2026-01-02": 99, "2026-01-09": 14], into: h)
        XCTAssertEqual(n, 1)
        XCTAssertEqual(out.days["2026-01-01"]?.respRate, 15.5)
        XCTAssertEqual(out.days["2026-01-01"]?.respSource, "whoop")
        XCTAssertEqual(out.days["2026-01-02"]?.respRate, 16.0)
        XCTAssertNil(out.days["2026-01-09"])
    }

    func testMergeFillsBreathingIntoKnownDays() {
        var current = HistoryData()
        var old = DayRecord(day: "2026-01-01", source: "whoop")
        old.recovery = 70
        current.days["2026-01-01"] = old
        var incoming = HistoryData()
        var fresh = DayRecord(day: "2026-01-01", source: "whoop")
        fresh.recovery = 10
        fresh.respRate = 15.9
        fresh.respSource = "whoop"
        incoming.days["2026-01-01"] = fresh
        let (out, added) = HistoryImport.merge(incoming, into: current)
        XCTAssertEqual(added, 0)
        XCTAssertEqual(out.days["2026-01-01"]?.recovery, 70)
        XCTAssertEqual(out.days["2026-01-01"]?.respRate, 15.9)
    }
}

/// Repeatable noise for tests.
private struct Seeded {
    private var s: UInt64
    init(_ seed: UInt64) { s = seed &* 0x9E3779B97F4A7C15 | 1 }
    mutating func next() -> Double {
        s ^= s << 13; s ^= s >> 7; s ^= s << 17
        return Double(s >> 11) / Double(1 << 53)
    }
    mutating func gauss() -> Double {
        let u = max(next(), 1e-12), v = next()
        return sqrt(-2 * log(u)) * cos(2 * .pi * v)
    }
}
