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

    func testSymptoms() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let ms: (Int, Int) -> Int64 = { day, hour in Int64(cal.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour))!.timeIntervalSince1970 * 1000) }
        XCTAssertEqual(BodyMath.nightKey(ms(15, 23), calendar: cal), "2026-11-16")
        XCTAssertEqual(BodyMath.nightKey(ms(16, 3), calendar: cal), "2026-11-16")
        XCTAssertNil(BodyMath.busiestHours([ms(16, 14)], calendar: cal))
        let times = [ms(16, 13), ms(16, 14), ms(15, 14), ms(14, 15), ms(13, 8)]
        XCTAssertEqual(BodyMath.busiestHours(times, calendar: cal), 13)
        XCTAssertEqual(BodyMath.hourText(13), "1 PM")
        XCTAssertEqual(BodyMath.hourText(0), "midnight")

        var d = BodyData()
        d.addEvent(SymptomEvent(id: "a", time: 1, name: "Hot flashes"))
        d.rate("Joint aches", day: "2026-11-16", level: 5)
        XCTAssertEqual(d.ratings["2026-11-16"]?["Joint aches"], 3)
        d.rate("Joint aches", day: "2026-11-16", level: nil)
        XCTAssertNil(d.ratings["2026-11-16"])
        var other = BodyData()
        other.addEvent(SymptomEvent(id: "b", time: 2, name: "Night sweats"))
        other.rate("Mood", day: "2026-11-15", level: 2)
        XCTAssertEqual(d.merge(other), 1)
        XCTAssertEqual(d.events.map(\.id), ["b", "a"])
        XCTAssertEqual(d.ratings["2026-11-15"]?["Mood"], 2)
    }

    func testCycle() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        func d(_ m: Int, _ day: Int) -> Date { cal.date(from: DateComponents(year: 2026, month: m, day: day))! }
        func k(_ m: Int, _ day: Int) -> String { CycleMath.key(d(m, day), cal) }
        var flow: [String: Int] = [:]
        // Periods starting Jul 1, Jul 29, Aug 28, Sep 25, Oct 24 (28, 30, 28, 29 days), each 4 days long.
        for (m, day) in [(7, 1), (7, 29), (8, 28), (9, 25), (10, 24)] {
            for i in 0..<4 { flow[CycleMath.key(cal.date(byAdding: .day, value: i, to: d(m, day))!, cal)] = i == 3 ? 1 : 3 }
        }
        flow[k(10, 10)] = 1 // spotting mid-cycle doesn't start a period
        let st = CycleMath.starts(flow, cal)
        XCTAssertEqual(st, [d(7, 1), d(7, 29), d(8, 28), d(9, 25), d(10, 24)])
        XCTAssertEqual(CycleMath.lengths(st, cal), [28, 30, 28, 29])
        let p = CycleMath.predict(flow, today: d(11, 9), cal)!
        XCTAssertEqual(p.cycleDay, 17)
        XCTAssertEqual(p.shortest, 28)
        XCTAssertEqual(p.longest, 30)
        XCTAssertEqual(p.nextFrom, d(11, 21))
        XCTAssertEqual(p.nextTo, d(11, 23))
        XCTAssertTrue(p.fromHistory)

        // One period only: assumes a typical cycle.
        let one = CycleMath.predict([k(11, 1): 3], today: d(11, 9), cal)!
        XCTAssertFalse(one.fromHistory)
        XCTAssertEqual(one.cycleDay, 9)

        var notes: [String: [String]] = [:]
        for s in st.suffix(4) { notes[CycleMath.key(cal.date(byAdding: .day, value: -3, to: s)!, cal)] = ["Bloating"] }
        notes[k(10, 1)] = ["Cramps"]
        XCTAssertEqual(CycleMath.beforePeriod(notes, starts: st, cal), ["Bloating"])
    }
}
