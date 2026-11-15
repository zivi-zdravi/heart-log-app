import XCTest

/// Synthetic foods only.
final class AIMealTests: XCTestCase {
    private let json = """
    {"items":[{"name":"Eggs, scrambled","usda_query":"egg scrambled","amount_text":"2 large","grams":120,"calories":180,"protein_g":12,"carbs_g":2,"fat_g":14,"guess":false},
              {"name":"Butter","usda_query":"butter","amount_text":"1 tsp","grams":5,"calories":35,"protein_g":0,"carbs_g":0,"fat_g":4,"guess":true,"note":"you didn't say how much"}],
     "calories_low":215,"calories_high":215}
    """

    private func usda(_ name: String, kcalPer100: Double) -> FoodItem {
        FoodItem(id: "usda:1", name: name, brand: nil, source: .usda, per100g: Nutrients(kcal: kcalPer100, protein: 10, carbs: 1, fat: 11), servings: [], ingredients: nil)
    }

    func testDecodesServerReply() throws {
        let r = try JSONDecoder().decode(AIMealResult.self, from: Data(json.utf8))
        XCTAssertEqual(r.items.count, 2)
        XCTAssertTrue(r.items[1].guess)
        XCTAssertEqual(r.items[1].note, "you didn't say how much")
        XCTAssertNil(r.unclear)
    }

    func testUsesUSDAWhenItAgrees() throws {
        let item = try JSONDecoder().decode(AIMealResult.self, from: Data(json.utf8)).items[0]
        let f = AIMeal.food(for: item, usdaMatch: usda("Egg, scrambled", kcalPer100: 149))
        XCTAssertTrue(f.fromUSDA)
        XCTAssertEqual(f.nutrients.kcal, 149 * 1.2, accuracy: 0.01)
        XCTAssertEqual(f.serving, Serving(label: "2 large", grams: 120))
    }

    func testKeepsAIEstimateWhenUSDAMatchIsOff() throws {
        let item = try JSONDecoder().decode(AIMealResult.self, from: Data(json.utf8)).items[0]
        // Egg white: about a third of the calories. Probably the wrong food.
        let f = AIMeal.food(for: item, usdaMatch: usda("Egg white", kcalPer100: 52))
        XCTAssertFalse(f.fromUSDA)
        XCTAssertEqual(f.food.source, .ai)
        XCTAssertEqual(f.nutrients.kcal, 180, accuracy: 0.01)
        XCTAssertEqual(f.nutrients.fat, 14, accuracy: 0.01)
        XCTAssertFalse(AIMeal.food(for: item, usdaMatch: nil).fromUSDA)
    }

    func testCaloriesTextSingleOrRange() throws {
        let r = try JSONDecoder().decode(AIMealResult.self, from: Data(json.utf8))
        let foods = r.items.map { AIMeal.food(for: $0, usdaMatch: nil) }
        XCTAssertEqual(AIMeal.caloriesText(foods, low: 215, high: 215), "215")
        XCTAssertEqual(AIMeal.caloriesText(foods, low: 160, high: 280), "160 to 280")
    }

    func testAISourceRoundTrips() throws {
        let f = AIMeal.estimated(AIMealResult.Item(name: "Toast", usda_query: "toast", amount_text: "1 slice", grams: 50, calories: 140, protein_g: 5, carbs_g: 26, fat_g: 2, guess: false, note: nil))
        let back = try JSONDecoder().decode(FoodItem.self, from: JSONEncoder().encode(f))
        XCTAssertEqual(back, f)
        XCTAssertEqual(back.sourceLabel, "Estimated by AI")
    }

    func testOldSettingsFileKeepsDefaults() throws {
        XCTAssertEqual(try JSONDecoder().decode(AISettings.self, from: Data("{}".utf8)), AISettings())
    }
}
