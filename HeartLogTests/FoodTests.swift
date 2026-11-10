import XCTest

final class FoodTests: XCTestCase {
    private func food(_ name: String, ingredients: String? = nil) -> FoodItem {
        FoodItem(id: "t:\(name)", name: name, brand: nil, source: .usda, per100g: Nutrients(kcal: 59, protein: 10.2, carbs: 3.6, fat: 0.4),
                 servings: [Serving(label: "1 cup (245 g)", grams: 245)], ingredients: ingredients)
    }

    func testScaling() {
        let f = food("Greek yogurt")
        let n = f.nutrients(amount: 1, serving: f.servings[0])
        XCTAssertEqual(n.kcal, 144.55, accuracy: 0.01)
        XCTAssertEqual(n.protein, 24.99, accuracy: 0.01)
        let half = f.nutrients(amount: 50, serving: Serving(label: "g", grams: 1))
        XCTAssertEqual(half.kcal, 29.5, accuracy: 0.01)
        XCTAssertEqual(f.allServings.map(\.label), ["1 cup (245 g)", "g", "oz"])
    }

    func testCustomServingsStayAsEntered() {
        var f = food("Burrito bowl")
        f.source = .custom
        f.servings = [Serving(label: "1 bowl", grams: 100)]
        XCTAssertEqual(f.allServings.map(\.label), ["1 bowl"])
    }

    func testGoal() {
        XCTAssertEqual(MealMath.goal(aim: .maintain, usualBurn: 2100, restingBurn: 1350), 2100)
        XCTAssertEqual(MealMath.goal(aim: .lose, usualBurn: 2100, restingBurn: 1350), 1700)
        XCTAssertEqual(MealMath.goal(aim: .gain, usualBurn: 2100, restingBurn: 1350), 2350)
        XCTAssertEqual(MealMath.goal(aim: .lose, usualBurn: 3000, restingBurn: 1600), 2500)
        // Never below resting burn.
        XCTAssertEqual(MealMath.goal(aim: .lose, usualBurn: 1500, restingBurn: 1410), 1450)
    }

    func testAvoidMatching() {
        XCTAssertEqual(MealMath.avoidMatches(food("Greek yogurt, plain"), avoid: ["Yogurt", "gurt"]), ["Yogurt"])
        XCTAssertEqual(MealMath.avoidMatches(food("Bread", ingredients: "Wheat flour, MILK, salt"), avoid: ["milk"]), ["milk"])
        XCTAssertEqual(MealMath.avoidMatches(food("Eggplant, roasted"), avoid: ["egg"]), [])
        XCTAssertEqual(MealMath.avoidMatches(food("Eggs, scrambled"), avoid: ["egg"]), ["egg"])
        XCTAssertEqual(MealMath.avoidMatches(food("Salsa with jalapeños"), avoid: ["jalapeno"]), ["jalapeno"])
        XCTAssertEqual(MealMath.avoidMatches(food("Peanut butter cookie"), avoid: ["peanut butter", "  "]), ["peanut butter"])
    }

    func testMealSlotByHour() {
        XCTAssertEqual(MealSlot.at(hour: 7), .breakfast)
        XCTAssertEqual(MealSlot.at(hour: 13), .lunch)
        XCTAssertEqual(MealSlot.at(hour: 19), .dinner)
        XCTAssertEqual(MealSlot.at(hour: 23), .snacks)
    }

    func testParseUSDA() throws {
        let json = """
        {"totalHits":2,"foods":[
          {"fdcId":171304,"description":"YOGURT, GREEK, PLAIN, NONFAT","dataType":"SR Legacy",
           "foodNutrients":[{"nutrientNumber":"203","value":10.2},{"nutrientNumber":"204","value":0.39},
                            {"nutrientNumber":"205","value":3.6},{"nutrientNumber":"208","value":59}],
           "foodMeasures":[{"disseminationText":"1 container (6 oz)","gramWeight":170},
                           {"disseminationText":"Quantity not specified","gramWeight":0}]},
          {"fdcId":5,"description":"No energy","foodNutrients":[{"nutrientNumber":"203","value":1}]}
        ]}
        """
        let foods = FoodParse.usda(Data(json.utf8))
        XCTAssertEqual(foods.count, 1)
        let f = try XCTUnwrap(foods.first)
        XCTAssertEqual(f.id, "usda:171304")
        XCTAssertEqual(f.name, "Yogurt, greek, plain, nonfat")
        XCTAssertEqual(f.per100g, Nutrients(kcal: 59, protein: 10.2, carbs: 3.6, fat: 0.39))
        XCTAssertEqual(f.servings, [Serving(label: "1 container (6 oz) (170 g)", grams: 170)])
    }

    func testParseOpenFoodFacts() throws {
        let search = """
        {"count":1,"products":[{"code":"0123456789012","product_name":"Peanut Butter","brands":"Test Brand, Other",
          "serving_size":"2 tbsp (32 g)","serving_quantity":"32","ingredients_text":"Peanuts, salt",
          "nutriments":{"energy-kcal_100g":588,"proteins_100g":25,"carbohydrates_100g":20,"fat_100g":50}},
          {"code":"1","product_name":"","nutriments":{}}]}
        """
        let list = FoodParse.offSearch(Data(search.utf8))
        XCTAssertEqual(list.count, 1)
        let f = try XCTUnwrap(list.first)
        XCTAssertEqual(f.displayName, "Test Brand Peanut Butter")
        XCTAssertEqual(f.servings.first?.grams, 32)
        XCTAssertEqual(f.nutrients(amount: 1, serving: f.servings[0]).kcal, 188.16, accuracy: 0.01)
        XCTAssertEqual(MealMath.avoidMatches(f, avoid: ["peanut"]), ["peanut"])

        let barcode = """
        {"code":"999","status":1,"product":{"product_name":"Oat drink","nutriments":{"energy_100g":200,"proteins_100g":1}}}
        """
        let b = try XCTUnwrap(FoodParse.offBarcode(Data(barcode.utf8)))
        XCTAssertEqual(b.id, "off:999")
        XCTAssertEqual(b.per100g.kcal, 200 / 4.184, accuracy: 0.01)
        XCTAssertNil(FoodParse.offBarcode(Data(#"{"status":0}"#.utf8)))
    }

    func testEntryCodableRoundTrip() throws {
        let f = food("Oats")
        let e = MealEntry(id: "1", day: "2026-11-10", slot: .breakfast, time: 1, food: f, amount: 1.5, serving: f.servings[0])
        let back = try JSONDecoder().decode(MealEntry.self, from: JSONEncoder().encode(e))
        XCTAssertEqual(back, e)
        XCTAssertEqual(e.amountText, "1.5 1 cup (245 g)")
    }
}
