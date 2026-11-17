import XCTest

final class MacroTests: XCTestCase {
    func testAutomatic() {
        let t = MacroMath.automatic(calories: 1800, weightKg: 70, aim: .lose)
        XCTAssertEqual(t.protein, 112)
        XCTAssertEqual(t.fat, 60)
        XCTAssertEqual(t.carbs, 203)
        let noWeight = MacroMath.automatic(calories: 2000, weightKg: nil, aim: .maintain)
        XCTAssertEqual(noWeight.protein, 125)
    }

    func testSplit() {
        let t = MacroMath.fromSplit(calories: 2000, split: [30, 40, 30])
        XCTAssertEqual(t, MacroTargets(protein: 150, carbs: 200, fat: 67))
    }

    func testAdjustKeepsHundred() {
        let s = MacroMath.adjust([25, 45, 30], index: 0, to: 35)
        XCTAssertEqual(s.reduce(0, +), 100)
        XCTAssertEqual(s[0], 35)
        XCTAssertEqual(MacroMath.adjust([25, 45, 30], index: 2, to: 99).reduce(0, +), 100)
    }

    func testOldSettingsStillDecode() throws {
        let s = try JSONDecoder().decode(MealSettings.self, from: Data(#"{"setUp":true,"aim":"Gain","automatic":false,"manualGoal":2200,"avoid":["peanut"]}"#.utf8))
        XCTAssertTrue(s.setUp)
        XCTAssertEqual(s.aim, .gain)
        XCTAssertEqual(s.manualGoal, 2200)
        XCTAssertTrue(s.macrosAutomatic)
        XCTAssertEqual(s.split, [25, 45, 30])
        XCTAssertEqual(s.macroStyle, .rings)
    }
}
