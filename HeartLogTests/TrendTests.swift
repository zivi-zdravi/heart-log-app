import XCTest

final class TrendTests: XCTestCase {
    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 0)!
        c.firstWeekday = 1
        return c
    }

    private func day(_ d: Int) -> Date { cal.date(from: DateComponents(year: 2026, month: 11, day: d))! }

    func testWeekly() {
        // Nov 1 2026 is a Sunday, so Nov 1 to 7 is one week and Nov 8 starts the next.
        let v = (1...9).map { TrendValue(date: day($0), value: Double($0), app: $0 >= 9) }
        let w = TrendMath.weekly(v, calendar: cal)
        XCTAssertEqual(w.count, 2)
        XCTAssertEqual(w[0].mean, 4, accuracy: 0.001)
        XCTAssertEqual(w[0].low, 1)
        XCTAssertEqual(w[0].high, 7)
        XCTAssertFalse(w[0].app)
        XCTAssertEqual(w[1].mean, 8.5, accuracy: 0.001)
        XCTAssertTrue(w[1].app)
    }

    func testTrailingSkipsMissingDays() {
        let v = [1, 2, 3, 10].map { TrendValue(date: day($0), value: Double($0), app: false) }
        let t = TrendMath.trailing(v, calendar: cal)
        XCTAssertEqual(t.map(\.value), [1, 1.5, 2, 5])
    }

    func testDomain() {
        let d = TrendMath.domain([28, 34], minSpan: 15, floor: 0)
        XCTAssertEqual(d.upperBound - d.lowerBound, 15, accuracy: 0.001)
        XCTAssertTrue(d.contains(28) && d.contains(34))
        let low = TrendMath.domain([1, 2], minSpan: 10, floor: 0)
        XCTAssertEqual(low.lowerBound, 0)
        XCTAssertGreaterThanOrEqual(low.upperBound, 10)
    }

    func testChangeWords() {
        XCTAssertEqual(TrendMath.change(64, 59, tolerance: 1), "up from")
        XCTAssertEqual(TrendMath.change(55, 59, tolerance: 1), "down from")
        XCTAssertEqual(TrendMath.change(59.5, 59, tolerance: 1), "about the same as")
    }
}
