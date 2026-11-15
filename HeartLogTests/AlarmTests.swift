import XCTest

final class AlarmTests: XCTestCase {
    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return c
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    /// Weekdays on at 7:00, Thursday 5:30, weekends off.
    private var weekdays: AlarmSchedule {
        var s = AlarmSchedule.default
        for i in 0..<5 { s.days[i].on = true }
        s.days[3].minutes = 5 * 60 + 30
        return s
    }

    // Nov 14, 2026 is a Saturday.
    func testNextSkipsTheWeekend() {
        XCTAssertEqual(weekdays.next(after: date(2026, 11, 14, 12, 0), calendar: cal), date(2026, 11, 16, 7, 0))
    }

    func testThursdayUsesItsOwnTime() {
        XCTAssertEqual(weekdays.next(after: date(2026, 11, 18, 8, 0), calendar: cal), date(2026, 11, 19, 5, 30))
    }

    func testTodayLaterStillCounts() {
        XCTAssertEqual(weekdays.next(after: date(2026, 11, 16, 6, 0), calendar: cal), date(2026, 11, 16, 7, 0))
        XCTAssertEqual(weekdays.next(after: date(2026, 11, 16, 7, 0), calendar: cal), date(2026, 11, 17, 7, 0))
    }

    func testCancelTheNextAlarmMovesToTheOneAfter() {
        var s = weekdays
        s.skipThrough = date(2026, 11, 16, 7, 0)
        XCTAssertEqual(s.next(after: date(2026, 11, 14, 12, 0), calendar: cal), date(2026, 11, 17, 7, 0))
    }

    func testAllOffMeansNoAlarm() {
        XCTAssertNil(AlarmSchedule.default.next(after: date(2026, 11, 14, 12, 0), calendar: cal))
    }

    func testMondayIsIndexZero() {
        XCTAssertEqual(AlarmSchedule.index(of: date(2026, 11, 16, 9, 0), calendar: cal), 0)
        XCTAssertEqual(AlarmSchedule.index(of: date(2026, 11, 15, 9, 0), calendar: cal), 6)
    }

    // MARK: Bytes

    func testTimestampIsLittleEndianWithSubseconds() {
        let t = Date(timeIntervalSince1970: 1_794_729_600.5) // .5 s -> 16384/32768
        XCTAssertEqual(BandAlarm.timestamp(t), [0x80, 0x66, 0xF9, 0x6A, 0x00, 0x40])
    }

    func testGen5SetBodyLayout() {
        let t = Date(timeIntervalSince1970: 1_794_729_600)
        let b = BandAlarm.setBody(t, generation: .gen5)
        XCTAssertEqual(b.count, 21)
        XCTAssertEqual(Array(b[0..<2]), [0x04, 0x01]) // revision 4, slot 1 (never 0)
        XCTAssertEqual(Array(b[2..<8]), BandAlarm.timestamp(t))
        XCTAssertEqual(Array(b[8..<20]), [47, 152, 0, 0, 0, 0, 0, 0, 0, 0, 7, 30])
        XCTAssertEqual(b[20], 0) // crescendo off
    }

    func testGen4SetBodyIsRevisionOne() {
        let b = BandAlarm.setBody(Date(timeIntervalSince1970: 1_794_729_600), generation: .gen4)
        XCTAssertEqual(b.count, 9)
        XCTAssertEqual(b[0], 0x01)
    }

    func testDisableAndBuzzBodies() {
        XCTAssertEqual(BandAlarm.disableBody(.gen5), [0x02, 0xFF])
        XCTAssertEqual(BandAlarm.disableBody(.gen4), [0x01])
        let buzz = BandAlarm.testBuzz(.gen5)
        XCTAssertEqual(buzz.opcode, 0x13)
        XCTAssertEqual(buzz.body.last, 1) // loop once, not the wake alarm's 7
        XCTAssertEqual(BandAlarm.setClockBody(Date(timeIntervalSince1970: 1_794_729_600)).count, 8)
    }

    func testAlarmCommandsAreNotBlocked() {
        let g = BandGeneration.gen5
        XCTAssertNoThrow(try BandCommand.build(sequence: 1, opcode: BandOpcode.setAlarmTime, payload: BandAlarm.setBody(Date(), generation: g), generation: g))
        XCTAssertNoThrow(try BandCommand.build(sequence: 1, opcode: BandOpcode.disableAlarm, payload: BandAlarm.disableBody(g), generation: g))
        XCTAssertNoThrow(try BandCommand.build(sequence: 1, opcode: BandOpcode.setClock, payload: BandAlarm.setClockBody(Date()), generation: g))
    }
}

final class RelativeWordingTests: XCTestCase {
    func testCountsCalendarDays() {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let sat = c.date(from: DateComponents(year: 2026, month: 11, day: 14, hour: 17, minute: 54))!
        let mon = c.date(from: DateComponents(year: 2026, month: 11, day: 16, hour: 7))!
        let sun = c.date(from: DateComponents(year: 2026, month: 11, day: 15, hour: 7))!
        XCTAssertEqual(AlarmSchedule.relative(mon, from: sat, calendar: c), "in 2 days")
        XCTAssertEqual(AlarmSchedule.relative(sun, from: sat, calendar: c), "tomorrow")
        XCTAssertEqual(AlarmSchedule.relative(sat.addingTimeInterval(3600), from: sat, calendar: c), "today")
    }
}
