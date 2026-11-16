import XCTest

final class DetailTests: XCTestCase {
    private let body = Metrics.Body(kg: 70, cm: 168, age: 51, female: true)

    func testHeadline() {
        XCTAssertEqual(DetailMath.recoveryHeadline(nil), "No recovery yet")
        XCTAssertEqual(DetailMath.recoveryHeadline(80), "Well recovered")
        XCTAssertEqual(DetailMath.recoveryHeadline(50), "Moderately recovered")
        XCTAssertEqual(DetailMath.recoveryHeadline(20), "Low recovery")
    }

    func testReason() {
        XCTAssertEqual(DetailMath.recoveryReason(recovery: 70, hrv: 31, usualHRV: 30, rhr: 55, usualRHR: 54),
                       "HRV and resting heart rate both in your usual range. Room for a harder day.")
        XCTAssertEqual(DetailMath.recoveryReason(recovery: 25, hrv: 20, usualHRV: 30, rhr: 55, usualRHR: 54),
                       "HRV is below your usual. Keep today light.")
        XCTAssertEqual(DetailMath.recoveryReason(recovery: 50, hrv: nil, usualHRV: nil, rhr: nil, usualRHR: nil),
                       "Not enough nights yet to compare with your usual. A normal day is fine.")
        XCTAssertEqual(DetailMath.recoveryReason(recovery: nil, hrv: 30, usualHRV: 30, rhr: 50, usualRHR: 50),
                       "Shows after a night with the band on.")
    }

    func testUsualRange() {
        XCTAssertNil(DetailMath.usualRange([1, 2, 3, 4]))
        let r = DetailMath.usualRange([10, 20, 30, 40, 50])!
        XCTAssertEqual(r.lowerBound, 20, accuracy: 0.001)
        XCTAssertEqual(r.upperBound, 40, accuracy: 0.001)
    }

    func testTrendWord() {
        XCTAssertNil(DetailMath.trendWord([1, 2, 3], tolerance: 1))
        XCTAssertEqual(DetailMath.trendWord(Array(repeating: 30.0, count: 20), tolerance: 1), "steady")
        XCTAssertEqual(DetailMath.trendWord(Array(repeating: 30.0, count: 13) + Array(repeating: 35.0, count: 7), tolerance: 1), "rising")
        XCTAssertEqual(DetailMath.trendWord(Array(repeating: 30.0, count: 13) + Array(repeating: 25.0, count: 7), tolerance: 1), "falling")
    }

    func testMovers() {
        var nights: [DetailMath.Night] = []
        for _ in 0..<4 { nights.append(.init(value: 25, prevStrain: 16, asleepMin: 450)) }
        for _ in 0..<4 { nights.append(.init(value: 32, prevStrain: 8, asleepMin: 450)) }
        XCTAssertEqual(DetailMath.movers(nights, unit: "ms", minDiff: 3), ["Lower after high-strain days (by about 7 ms)."])
        XCTAssertEqual(DetailMath.movers(Array(nights.prefix(5)), unit: "ms", minDiff: 3), [])
    }

    func testThroughNight() {
        // Five minutes of steady 1-second readings with gently varying beat timing.
        let s = (0..<300).map { i in Sample(t: Int64(i) * 1000, hr: 60, rr: [1000 + (i % 2 == 0 ? 20 : -20)]) }
        let hrv = DetailMath.hrvThroughNight(s)
        XCTAssertEqual(hrv.count, 1)
        XCTAssertEqual(hrv[0].value, 40, accuracy: 0.001)
        let hr = DetailMath.heartRateThroughNight(s)
        XCTAssertEqual(hr, [DetailMath.Point(t: 0, value: 60)])
    }

    func testHourlyCalories() {
        let start: Int64 = 0
        let now: Int64 = 2 * 3_600_000 + 1_800_000
        let h = DetailMath.hourlyCalories([], dayStart: start, now: now, body: body, bounds: [100, 120, 140, 160, 180])
        XCTAssertEqual(h.count, 3)
        let perMin = Metrics.bmrPerMinute(body)
        XCTAssertEqual(h[0], perMin * 60, accuracy: 0.001)
        XCTAssertEqual(h[2], perMin * 30, accuracy: 0.001)
        XCTAssertEqual(DetailMath.likelyByBedtime(burned: 100, now: 0, dayEnd: 60_000, body: body), 100 + perMin, accuracy: 0.001)
    }

    func testSteps() {
        XCTAssertEqual(DetailMath.stepsLine(steps: 6240, goal: 8000), "1,760 to go. About a 20-minute walk.")
        XCTAssertEqual(DetailMath.stepsLine(steps: 9000, goal: 8000), "Goal reached.")
        XCTAssertEqual(DetailMath.walkMinutes(100), 5)
    }
}
