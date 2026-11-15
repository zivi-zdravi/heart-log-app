import XCTest

final class NotifyTests: XCTestCase {
    func testDefaultsMatchMockup() {
        let s = NotifySettings()
        XCTAssertEqual(s.lowBattery, .phone)
        XCTAssertEqual(s.lowBatteryAt, 20)
        XCTAssertEqual(s.charger, .off)
        XCTAssertEqual(s.goneQuiet, .phone)
        XCTAssertEqual(s.alarmNotSaved, .phone)
        XCTAssertEqual(s.noAlarmCheckIn, .off)
        XCTAssertEqual(s.windDown, .band)
        XCTAssertEqual(s.stepGoal, .phone)
        XCTAssertEqual(s.possibleActivity, .off)
        XCTAssertEqual(s.water, .band)
        XCTAssertEqual(s.waterEveryHours, 2)
        XCTAssertTrue(s.quietOn)
        XCTAssertEqual(s.quietStart, 22 * 60)
        XCTAssertEqual(s.quietEnd, 7 * 60)
    }

    func testOldFileKeepsChoicesAndFillsNewKeys() throws {
        let json = #"{"water":"both","quietOn":false}"#.data(using: .utf8)!
        let s = try JSONDecoder().decode(NotifySettings.self, from: json)
        XCTAssertEqual(s.water, .both)
        XCTAssertFalse(s.quietOn)
        XCTAssertEqual(s.stepGoalCount, 8000)
    }

    func testRoutes() {
        XCTAssertTrue(NotifyRoute.both.toPhone && NotifyRoute.both.toBand)
        XCTAssertFalse(NotifyRoute.band.toPhone)
        XCTAssertFalse(NotifyRoute.off.toPhone || NotifyRoute.off.toBand)
    }

    func testQuietAcrossMidnight() {
        let s = NotifySettings()
        XCTAssertTrue(NotifyRules.isQuiet(23 * 60, s))
        XCTAssertTrue(NotifyRules.isQuiet(3 * 60, s))
        XCTAssertFalse(NotifyRules.isQuiet(7 * 60, s))
        XCTAssertFalse(NotifyRules.isQuiet(12 * 60, s))
        XCTAssertTrue(NotifyRules.isQuiet(22 * 60, s))
        var off = s
        off.quietOn = false
        XCTAssertFalse(NotifyRules.isQuiet(23 * 60, off))
    }

    func testQuietSameDay() {
        var s = NotifySettings()
        s.quietStart = 13 * 60
        s.quietEnd = 14 * 60
        XCTAssertTrue(NotifyRules.isQuiet(13 * 60 + 30, s))
        XCTAssertFalse(NotifyRules.isQuiet(14 * 60, s))
    }

    func testLowBatteryOnceThenRearms() {
        var sent = false
        var r = NotifyRules.lowBattery(level: 25, at: 20, sent: sent); XCTAssertFalse(r.fire); sent = r.sent
        r = NotifyRules.lowBattery(level: 19, at: 20, sent: sent); XCTAssertTrue(r.fire); sent = r.sent
        r = NotifyRules.lowBattery(level: 18, at: 20, sent: sent); XCTAssertFalse(r.fire); sent = r.sent
        r = NotifyRules.lowBattery(level: 22, at: 20, sent: sent); XCTAssertFalse(r.fire); XCTAssertTrue(r.sent); sent = r.sent
        r = NotifyRules.lowBattery(level: 19, at: 20, sent: sent); XCTAssertFalse(r.fire, "wobbling near the line doesn't repeat")
        r = NotifyRules.lowBattery(level: 60, at: 20, sent: sent); XCTAssertFalse(r.sent); sent = r.sent
        r = NotifyRules.lowBattery(level: 19, at: 20, sent: sent); XCTAssertTrue(r.fire)
    }

    func testWaterDue() {
        let h: Int64 = 3_600_000
        let woke: Int64 = 7 * h
        XCTAssertFalse(NotifyRules.waterDue(now: 8 * h, lastGlass: nil, lastReminder: nil, wokeAt: woke, everyHours: 2))
        XCTAssertTrue(NotifyRules.waterDue(now: 9 * h, lastGlass: nil, lastReminder: nil, wokeAt: woke, everyHours: 2))
        XCTAssertFalse(NotifyRules.waterDue(now: 9 * h, lastGlass: 8 * h, lastReminder: nil, wokeAt: woke, everyHours: 2), "a glass resets the clock")
        XCTAssertFalse(NotifyRules.waterDue(now: 10 * h, lastGlass: nil, lastReminder: 9 * h, wokeAt: woke, everyHours: 2))
        XCTAssertTrue(NotifyRules.waterDue(now: 11 * h, lastGlass: nil, lastReminder: 9 * h, wokeAt: woke, everyHours: 2))
    }

    func testWindDown() {
        // Wake 6:30 (390), need 8h (480): bed 22:30, wind-down 21:45.
        XCTAssertEqual(NotifyRules.windDownMinute(usualWakeMinute: 390, needMinutes: 480), 21 * 60 + 45)
        // Wake 8:00, need 7h: bed 1:00, wind-down 0:15.
        XCTAssertEqual(NotifyRules.windDownMinute(usualWakeMinute: 480, needMinutes: 420), 15)
        // Wake 7:00, need 7h15: bed 23:45, wind-down 23:00.
        XCTAssertEqual(NotifyRules.windDownMinute(usualWakeMinute: 420, needMinutes: 435), 23 * 60)
    }

    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    func testCheckIn() {
        var s = AlarmSchedule.default
        s.days[0] = AlarmDay(on: true, minutes: 7 * 60) // Monday
        // Sunday Nov 15 2026, 7 PM: Monday alarm is on and set.
        let sun = date(2026, 11, 15, 19)
        XCTAssertFalse(NotifyRules.checkInDue(schedule: s, now: sun, calendar: cal))
        // Cancelled through Monday: due.
        var skipped = s
        skipped.skipThrough = date(2026, 11, 16, 12)
        XCTAssertTrue(NotifyRules.checkInDue(schedule: skipped, now: sun, calendar: cal))
        // Saturday: Sunday isn't an alarm day, so nothing.
        XCTAssertFalse(NotifyRules.checkInDue(schedule: skipped, now: date(2026, 11, 14, 19), calendar: cal))
    }
}
