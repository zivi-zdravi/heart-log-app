import XCTest

final class BodyTests: XCTestCase {
    private func reading(_ id: String, _ t: Int64, _ s: Int, _ d: Int) -> BPReading {
        BPReading(id: id, time: t, systolic: s, diastolic: d, pulse: nil)
    }

    func testValid() {
        XCTAssertTrue(BodyMath.valid(systolic: 118, diastolic: 76, pulse: 62))
        XCTAssertFalse(BodyMath.valid(systolic: 76, diastolic: 118, pulse: nil))
        XCTAssertFalse(BodyMath.valid(systolic: 18, diastolic: 7, pulse: nil))
        XCTAssertFalse(BodyMath.valid(systolic: 118, diastolic: 76, pulse: 600))
    }

    func testSaveAndMerge() {
        var d = BodyData()
        d.save(reading("a", 1, 120, 80))
        d.save(reading("b", 3, 130, 85))
        d.save(reading("a", 1, 121, 80))
        XCTAssertEqual(d.bp.map(\.id), ["b", "a"])
        XCTAssertEqual(d.bp[1].systolic, 121)
        var other = BodyData()
        other.save(reading("c", 2, 110, 70))
        other.save(reading("a", 1, 999, 1))
        XCTAssertEqual(d.merge(other), 1)
        XCTAssertEqual(d.bp.map(\.id), ["b", "c", "a"])
        XCTAssertEqual(d.bp[2].systolic, 121)
    }

    func testAverageAndRecent() {
        let rs = [reading("a", 0, 120, 80), reading("b", 86_400_000 * 40, 130, 85)]
        XCTAssertEqual(BodyMath.average(rs)?.systolic, 125)
        XCTAssertEqual(BodyMath.average(rs)?.diastolic, 83)
        XCTAssertEqual(BodyMath.recent(rs, days: 30, now: 86_400_000 * 41).map(\.id), ["b"])
        XCTAssertNil(BodyMath.average([]))
    }

    func testTolerantDecode() throws {
        let d = try JSONDecoder().decode(BodyData.self, from: Data(#"{"settings":{"bloodPressure":true}}"#.utf8))
        XCTAssertTrue(d.settings.bloodPressure)
        XCTAssertTrue(d.settings.includeInAsk)
        XCTAssertEqual(d.settings.symptoms, BodyMath.defaultSymptoms)
        XCTAssertEqual(d.bp, [])
    }

    func testWhen() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 16, hour: 15))!
        let ms: (Int, Int) -> Int64 = { day, hour in Int64(cal.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour))!.timeIntervalSince1970 * 1000) }
        XCTAssertEqual(BodyMath.when(ms(16, 7), now: now, calendar: cal), "this morning")
        XCTAssertEqual(BodyMath.when(ms(16, 19), now: now, calendar: cal), "this evening")
        XCTAssertEqual(BodyMath.when(ms(15, 7), now: now, calendar: cal), "yesterday")
    }
}
