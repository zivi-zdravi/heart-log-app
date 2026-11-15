import XCTest

final class WaterTests: XCTestCase {
    func testGlassesAndLabel() {
        var w = WaterData()
        w.add("2026-11-14", at: 1000, fromTap: true)
        w.add("2026-11-14", at: 2000, fromTap: false)
        XCTAssertEqual(w.ounces("2026-11-14"), 16)
        XCTAssertEqual(w.label("2026-11-14"), "16 / 64 oz")
        XCTAssertEqual(w.days["2026-11-14"]?.lastFromTap, false)
        w.remove("2026-11-14")
        w.remove("2026-11-14")
        w.remove("2026-11-14") // never below zero
        XCTAssertEqual(w.days["2026-11-14"]?.glasses, 0)
        XCTAssertNil(w.days["2026-11-14"]?.lastAt)
    }

    func testSavedWaterRoundTrips() throws {
        var w = WaterData()
        w.goalOz = 128
        w.tapAction = .activity
        w.add("2026-11-14", at: 5, fromTap: true)
        let back = try JSONDecoder().decode(WaterData.self, from: JSONEncoder().encode(w))
        XCTAssertEqual(back, w)
        XCTAssertEqual(back.label("2026-11-14"), "8 / 128 oz")
    }
}

final class TapGuardTests: XCTestCase {
    private let now: Double = 1_794_700_000

    private func act(tap: Double? = nil, offset: Int? = 0, last: Double? = nil, alarm: Double? = nil, fired: Double? = nil) -> Bool {
        TapGuard.shouldAct(tapBandSec: UInt32(tap ?? now), now: now, clockOffset: offset, lastActed: last,
                           alarm: alarm.map { Date(timeIntervalSince1970: $0) },
                           alarmFired: fired.map { Date(timeIntervalSince1970: $0) })
    }

    func testFreshTapActs() { XCTAssertTrue(act()) }

    func testOldTapFromHistoryIsIgnored() {
        XCTAssertFalse(act(tap: now - 3600))
        XCTAssertTrue(act(tap: now - 3))
    }

    func testBandClockOffsetIsApplied() {
        // Band runs 100 s ahead: a tap stamped now+100 happened now.
        XCTAssertTrue(act(tap: now + 100, offset: 100))
    }

    func testUnsetBandClockSkipsTheAgeCheck() {
        XCTAssertTrue(act(tap: 5000))
    }

    func testDebounce() {
        XCTAssertFalse(act(last: now - 1))
        XCTAssertTrue(act(last: now - 3))
    }

    func testTapsAroundTheAlarmNeverLogAnything() {
        XCTAssertFalse(act(alarm: now + 30))        // a minute before
        XCTAssertFalse(act(alarm: now - 300))       // 5 minutes after
        XCTAssertTrue(act(alarm: now - 700))        // well after
        XCTAssertTrue(act(alarm: now + 3600))       // alarm still an hour away
        XCTAssertFalse(act(fired: now - 120))       // band said it just fired
        XCTAssertTrue(act(fired: now - 400))
    }
}
