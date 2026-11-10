import XCTest

final class SleepTests: XCTestCase {
    private let base: Int64 = 28_333_333 * 60_000

    /// 20 hours, a reading every 3 seconds: awake, then 8 hours of low heart rate with one 5-minute wake-up.
    private func night() -> [Sample] {
        var s: [Sample] = []
        for m in 0..<1200 {
            let hr: Int
            switch m {
            case 60..<90: hr = 110
            case 0..<270: hr = 75
            case 480..<485: hr = 80
            case 270..<750: hr = 55
            default: hr = 75
            }
            for i in 0..<20 { s.append(Sample(t: base + Int64(m) * 60_000 + Int64(i) * 3000, hr: hr, rr: [])) }
        }
        return s
    }

    func testDetectsSleepWindow() throws {
        let p = try XCTUnwrap(SleepMath.detect(night()))
        XCTAssertEqual(p.onset, base + 270 * 60_000)
        XCTAssertEqual(p.wake, base + 750 * 60_000)
        XCTAssertEqual(p.inBedMin, 480, accuracy: 0.001)
        XCTAssertEqual(p.asleepMin, 475, accuracy: 0.001)
        XCTAssertEqual(p.awakeEvents, 1)
    }

    func testNoSleepWithoutEnoughData() {
        XCTAssertNil(SleepMath.detect(Array(night().prefix(2000))))
    }

    func testManualWindow() {
        let p = SleepMath.period(night(), onset: base + 300 * 60_000, wake: base + 700 * 60_000)
        XCTAssertEqual(p.inBedMin, 400, accuracy: 0.001)
        XCTAssertEqual(p.asleepMin, 395, accuracy: 0.001)
    }

    func testConsistency() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let p = SleepPeriod(onset: base, wake: base + 480 * 60_000, asleepMin: 450, inBedMin: 480)
        XCTAssertEqual(try XCTUnwrap(SleepMath.consistency(p, previous: [p, p], calendar: cal)), 100, accuracy: 0.001)
        let late = SleepPeriod(onset: base + 60 * 60_000, wake: base + 540 * 60_000, asleepMin: 450, inBedMin: 480)
        XCTAssertEqual(try XCTUnwrap(SleepMath.consistency(late, previous: [p], calendar: cal)), 162.78 - 21.71 * log(61), accuracy: 0.01)
        XCTAssertNil(SleepMath.consistency(p, previous: []))
    }

    func testScoresAndRecovery() {
        XCTAssertEqual(SleepMath.score(asleepMin: 400, needMin: 480, consistency: 70, efficiency: 90), 77.0117, accuracy: 0.01)
        XCTAssertEqual(SleepMath.score(asleepMin: 600, needMin: 480, consistency: 100, efficiency: 100), 100, accuracy: 0.001)
        XCTAssertEqual(SleepMath.recovery(hrv: 30, usualHRV: 30, sleepScore: 80), 63.91, accuracy: 0.01)
        XCTAssertEqual(SleepMath.recovery(hrv: 5, usualHRV: 60, sleepScore: 0), 1, accuracy: 0.001)
        XCTAssertEqual(SleepMath.sleepNeed(base: 460, prevStrain: 15, prevDebt: 200), 460 + 20 + 60, accuracy: 0.001)
        XCTAssertEqual(SleepMath.strainTarget(recovery: 90), 17, accuracy: 0.001)
    }

    func testLevels() {
        XCTAssertEqual(SleepMath.level(67), .high)
        XCTAssertEqual(SleepMath.level(66), .mid)
        XCTAssertEqual(SleepMath.level(34), .mid)
        XCTAssertEqual(SleepMath.level(33), .low)
    }
}
