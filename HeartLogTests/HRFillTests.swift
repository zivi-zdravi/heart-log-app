import XCTest

/// Synthetic readings only. No real person's data.
final class HRFillTests: XCTestCase {
    private func sec(_ t: Int64, hr: Int, steps: Int = 0, activity: Int = 0) -> BandSecond {
        BandSecond(t: t, hr: hr, rr: [], gravity: nil, steps: steps, activity: activity, sleepState: 0)
    }

    private let t0: Int64 = 1_800_000_000

    func testBandFillsOnlyTheGap() {
        // Live readings for the first and last 10 minutes, nothing in the middle 30.
        let live = (0..<600).map { Sample(t: (t0 + Int64($0)) * 1000, hr: 75, rr: []) }
            + (2400..<3000).map { Sample(t: (t0 + Int64($0)) * 1000, hr: 75, rr: []) }
        let band = (0..<3000).map { sec(t0 + Int64($0), hr: 120) }
        let merged = HRFill.merge(live: live, band: band)
        // 600 + 600 live, plus band seconds more than 5 s from any live reading.
        XCTAssertEqual(merged.count, 1200 + (2394 - 605 + 1))
        XCTAssertEqual(merged.map(\.t), merged.map(\.t).sorted())
        XCTAssertEqual(merged.filter { $0.hr == 75 }.count, 1200, "live readings win where both exist")
    }

    func testWalkWithoutPhoneGivesStrain() {
        let bounds = Metrics.zoneBounds(maxHR: 170, resting: 55)
        let band = (0..<1800).map { sec(t0 + Int64($0), hr: 115) }
        let merged = HRFill.merge(live: [], band: band)
        XCTAssertGreaterThan(Metrics.strain(zoneSeconds: Metrics.zoneSeconds(merged, bounds)), 3)
    }

    func testSkipsZeroReadings() {
        XCTAssertTrue(HRFill.merge(live: [], band: (0..<60).map { sec(t0 + Int64($0), hr: 0) }).isEmpty)
    }

    func testMovesFromWalkLabel() {
        // Labelled walking the whole time, about 60 steps a minute.
        let band = (0..<(25 * 60)).map { sec(t0 + Int64($0), hr: 90, steps: $0, activity: 1) }
        let spans = HRFill.moves(band)
        XCTAssertEqual(spans.count, 1)
        XCTAssertGreaterThanOrEqual((spans[0].end - spans[0].start) / 60_000, 24)
    }

    func testMovesFromStepsAlone() {
        // About 96 steps a minute, label unknown.
        var steps = 0
        let band: [BandSecond] = (0..<(15 * 60)).map { i in
            if i % 5 != 0 { steps += 2 }
            return sec(t0 + Int64(i), hr: 88, steps: steps % 65_536)
        }
        XCTAssertEqual(HRFill.moves(band).count, 1)
    }

    func testPotteringAroundIsNotAMove() {
        // Walk label on half of each minute, about 30 steps a minute: moving around the house.
        var band: [BandSecond] = []
        for i in 0..<(40 * 60) {
            let label = (i / 30) % 2 == 0 ? 1 : 0
            band.append(sec(t0 + Int64(i), hr: 98, steps: i / 2, activity: label))
        }
        XCTAssertTrue(HRFill.moves(band).isEmpty)
    }

    func testShortOrStillIsNotAMove() {
        XCTAssertTrue(HRFill.moves((0..<(5 * 60)).map { sec(t0 + Int64($0), hr: 90, activity: 1) }).isEmpty)
        XCTAssertTrue(HRFill.moves((0..<(30 * 60)).map { sec(t0 + Int64($0), hr: 70) }).isEmpty)
    }

    func testUnionJoinsOverlaps() {
        let a = Metrics.Span(start: 0, end: 10), b = Metrics.Span(start: 5, end: 20), c = Metrics.Span(start: 30, end: 40)
        XCTAssertEqual(HRFill.union([c, b, a]), [Metrics.Span(start: 0, end: 20), c])
    }
}
