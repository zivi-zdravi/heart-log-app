import XCTest

final class DoseTests: XCTestCase {
    private func katie() -> DoseData {
        var d = DoseData()
        let am = DoseGroup(id: "am", kind: .supplement, name: "Morning stack", time: 8 * 60)
        let pm = DoseGroup(id: "pm", kind: .supplement, name: "Evening stack", time: 20 * 60)
        d.groups = [pm, am]
        d.items = [
            DoseItem(id: "lt1", kind: .supplement, name: "Magnesium L-threonate", amount: 2, unit: "g", group: "am"),
            DoseItem(id: "coq", kind: .supplement, name: "CoQ10", amount: 100, unit: "mg", group: "am"),
            DoseItem(id: "col", kind: .supplement, name: "Collagen", amount: 10, unit: "g", kcal: 35, group: "am"),
            DoseItem(id: "lt2", kind: .supplement, name: "Magnesium L-threonate", amount: 2, unit: "g", group: "pm"),
            DoseItem(id: "cit", kind: .supplement, name: "Magnesium citrate", amount: 200, unit: "mg", group: "pm"),
        ]
        return d
    }

    func testSlotsInTimeOrderAndCounts() {
        var d = katie()
        let s = DoseMath.slots(d, .supplement)
        XCTAssertEqual(s.map(\.name), ["Morning stack", "Evening stack"])
        XCTAssertEqual(s[0].items.count, 3)
        d.taken["2026-11-20"] = ["lt1": 1, "coq": 1, "col": 1]
        XCTAssertEqual(DoseMath.counts(d, day: "2026-11-20", .supplement).taken, 3)
        XCTAssertEqual(DoseMath.counts(d, day: "2026-11-20", .supplement).total, 5)
        XCTAssertTrue(DoseMath.allTaken(d, day: "2026-11-20", s[0]))
        XCTAssertEqual(DoseMath.kcal(d, day: "2026-11-20"), 35)
        XCTAssertEqual(DoseMath.kcal(d, day: "2026-11-21"), 0)
    }

    func testDoubleTapPicksTheGroupThatIsDue() {
        var d = katie()
        XCTAssertEqual(DoseMath.due(d, day: "x", minute: 8 * 60 + 20)?.id, "am")  // 20 min after
        XCTAssertEqual(DoseMath.due(d, day: "x", minute: 7 * 60 + 40)?.id, "am")  // 20 min before
        XCTAssertNil(DoseMath.due(d, day: "x", minute: 12 * 60))                   // nothing near
        d.taken["x"] = ["lt1": 1, "coq": 1, "col": 1]
        XCTAssertNil(DoseMath.due(d, day: "x", minute: 8 * 60 + 20))               // already taken
        d.supplementsOn = false
        XCTAssertNil(DoseMath.due(d, day: "x", minute: 20 * 60))                   // switched off
    }

    func testRemindersSkipWhenTakenOrSent() {
        var d = katie()
        XCTAssertEqual(DoseMath.remindersDue(d, day: "x", minute: 8 * 60 + 1).map(\.id), ["am"])
        XCTAssertTrue(DoseMath.remindersDue(d, day: "x", minute: 7 * 60 + 59).isEmpty)
        d.reminded["am"] = "x"
        XCTAssertTrue(DoseMath.remindersDue(d, day: "x", minute: 8 * 60 + 1).isEmpty)
        d.reminded = [:]
        d.taken["x"] = ["lt1": 1, "coq": 1, "col": 1]
        XCTAssertTrue(DoseMath.remindersDue(d, day: "x", minute: 8 * 60 + 1).isEmpty)
    }

    func testLoneItemsAndOldFiles() throws {
        var d = DoseData()
        d.medicationsOn = true
        d.items = [DoseItem(id: "m", kind: .medication, name: "Medication B", amount: 25, unit: "mg", time: 21 * 60, reminder: .both)]
        let s = DoseMath.slots(d, .medication)
        XCTAssertEqual(s.first?.isGroup, false)
        XCTAssertEqual(s.first?.reminder, .both)
        XCTAssertEqual(DoseMath.doseText(d.items[0]), "25 mg")
        XCTAssertEqual(DoseMath.timeText(21 * 60), "9:00 PM")
        let old = try JSONDecoder().decode(DoseData.self, from: Data("{}".utf8))
        XCTAssertTrue(old.supplementsOn)
        XCTAssertFalse(old.medicationsInAsk)
    }
}
