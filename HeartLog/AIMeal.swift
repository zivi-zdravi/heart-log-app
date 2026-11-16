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

        init(name: String, usda_query: String, amount_text: String, grams: Double, calories: Double,
             protein_g: Double, carbs_g: Double, fat_g: Double, guess: Bool, note: String?) {
            self.name = name; self.usda_query = usda_query; self.amount_text = amount_text; self.grams = grams
            self.calories = calories; self.protein_g = protein_g; self.carbs_g = carbs_g; self.fat_g = fat_g
            self.guess = guess; self.note = note
        }

        // Claude occasionally leaves a field out or writes a number as text;
        // fill the gap instead of failing the whole meal.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            func num(_ k: CodingKeys) -> Double {
                if let v = try? c.decode(Double.self, forKey: k) { return v }
                if let s = try? c.decode(String.self, forKey: k) { return Double(s.filter { "0123456789.".contains($0) }) ?? 0 }
                return 0
            }
            name = (try? c.decode(String.self, forKey: .name)) ?? "Food"
            usda_query = (try? c.decode(String.self, forKey: .usda_query)) ?? name
            amount_text = (try? c.decode(String.self, forKey: .amount_text)) ?? "1 serving"
            grams = num(.grams)
            calories = num(.calories)
            protein_g = num(.protein_g)
            carbs_g = num(.carbs_g)
            fat_g = num(.fat_g)
            guess = (try? c.decode(Bool.self, forKey: .guess)) ?? false
            note = try? c.decode(String.self, forKey: .note)
        }
    }
    var items: [Item]
    var calories_low: Double
    var calories_high: Double
    var unclear: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = (try? c.decode([Item].self, forKey: .items)) ?? []
        let sum = items.reduce(0) { $0 + $1.calories }
        calories_low = (try? c.decode(Double.self, forKey: .calories_low)) ?? sum
        calories_high = (try? c.decode(Double.self, forKey: .calories_high)) ?? sum
        unclear = try? c.decode(String.self, forKey: .unclear)
        if items.isEmpty && (unclear ?? "").isEmpty { unclear = "Claude couldn't find any foods in that. Try describing it a little differently." }
    }
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
