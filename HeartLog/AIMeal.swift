import Foundation

/// What the home AI server sends back for a described or photographed meal.
struct AIMealResult: Codable, Equatable {
    struct Item: Codable, Equatable {
        var name: String
        var usda_query: String
        var amount_text: String
        var grams: Double
        var calories: Double
        var protein_g: Double
        var carbs_g: Double
        var fat_g: Double
        var guess: Bool
        var note: String?
    }
    var items: [Item]
    var calories_low: Double
    var calories_high: Double
    var unclear: String?
}

/// One food from an AI estimate, ready to log. `food` carries USDA's numbers
/// when a good match was found, otherwise the AI's own estimate.
struct AIFood: Equatable, Identifiable {
    var id = UUID().uuidString
    var item: AIMealResult.Item
    var food: FoodItem
    var grams: Double
    var fromUSDA: Bool

    var serving: Serving { Serving(label: item.amount_text, grams: grams) }
    var nutrients: Nutrients { food.nutrients(amount: 1, serving: serving) }
}

enum AIMeal {
    /// The AI's own estimate as a food (per 100 g from its totals for the weight it gave).
    static func estimated(_ i: AIMealResult.Item) -> FoodItem {
        let g = max(i.grams, 1)
        let f = 100 / g
        return FoodItem(id: "ai:\(i.name.lowercased())", name: i.name, brand: nil, source: .ai,
                        per100g: Nutrients(kcal: i.calories * f, protein: i.protein_g * f, carbs: i.carbs_g * f, fat: i.fat_g * f),
                        servings: [Serving(label: i.amount_text, grams: g)], ingredients: nil)
    }

    /// Uses the USDA match when it agrees with the AI within a factor of two
    /// for the same weight; a wilder gap usually means the search found the
    /// wrong food (e.g. "egg white" for "egg"), so the AI's estimate is kept.
    static func food(for i: AIMealResult.Item, usdaMatch: FoodItem?) -> AIFood {
        let grams = max(i.grams, 1)
        if let m = usdaMatch, m.per100g.kcal > 0 {
            let usdaKcal = m.per100g.kcal * grams / 100
            let ratio = i.calories > 0 ? usdaKcal / i.calories : 1
            if ratio >= 0.5 && ratio <= 2 {
                return AIFood(item: i, food: m, grams: grams, fromUSDA: true)
            }
        }
        return AIFood(item: i, food: estimated(i), grams: grams, fromUSDA: false)
    }

    /// Calories as the screen shows them: a single number for a clear
    /// description, a range when the AI gave one (photos).
    static func caloriesText(_ foods: [AIFood], low: Double, high: Double) -> String {
        let total = foods.reduce(0) { $0 + $1.nutrients.kcal }
        let spread = high - low
        if spread >= max(40, 0.1 * high), total > 0 {
            // Keep the AI's spread around the total we're actually logging.
            let half = spread / 2
            return "\(Int((max(0, total - half) / 10).rounded()) * 10) to \(Int(((total + half) / 10).rounded()) * 10)"
        }
        return "\(Int(total.rounded()))"
    }
}

/// Settings > AI. Server address and pass code live in the keychain;
/// these switches are saved in ai.json.
struct AISettings: Codable, Equatable {
    var describe = true
    var photos = true
    var ask = true

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        describe = try c.decodeIfPresent(Bool.self, forKey: .describe) ?? true
        photos = try c.decodeIfPresent(Bool.self, forKey: .photos) ?? true
        ask = try c.decodeIfPresent(Bool.self, forKey: .ask) ?? true
    }
}
