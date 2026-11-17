import Foundation

/// Calories and macros. Stored per 100 g on foods, and as totals on logged entries.
struct Nutrients: Codable, Equatable {
    var kcal: Double
    var protein: Double
    var carbs: Double
    var fat: Double

    static let zero = Nutrients(kcal: 0, protein: 0, carbs: 0, fat: 0)

    func scaled(_ f: Double) -> Nutrients {
        Nutrients(kcal: kcal * f, protein: protein * f, carbs: carbs * f, fat: fat * f)
    }

    static func + (a: Nutrients, b: Nutrients) -> Nutrients {
        Nutrients(kcal: a.kcal + b.kcal, protein: a.protein + b.protein, carbs: a.carbs + b.carbs, fat: a.fat + b.fat)
    }
}

struct Serving: Codable, Equatable, Hashable {
    var label: String
    var grams: Double
}

struct FoodItem: Codable, Equatable, Identifiable {
    enum Source: String, Codable { case usda, openFoodFacts, custom, ai }

    var id: String
    var name: String
    var brand: String?
    var source: Source
    var per100g: Nutrients
    var servings: [Serving]
    var ingredients: String?

    var displayName: String { brand.map { "\($0) \(name)" } ?? name }

    var sourceLabel: String {
        switch source {
        case .usda: return "USDA, everyday food"
        case .openFoodFacts: return "Packaged food (Open Food Facts)"
        case .custom: return "Entered by you"
        case .ai: return "Estimated by AI"
        }
    }

    /// Servings to offer, always ending with grams and ounces.
    var allServings: [Serving] {
        if source == .custom { return servings }
        var out = servings.filter { $0.grams > 0 }
        if !out.contains(where: { $0.label == "g" }) { out.append(Serving(label: "g", grams: 1)) }
        if !out.contains(where: { $0.label == "oz" }) { out.append(Serving(label: "oz", grams: 28.3495)) }
        return out
    }

    func nutrients(amount: Double, serving: Serving) -> Nutrients {
        per100g.scaled(amount * serving.grams / 100)
    }
}

enum MealSlot: String, Codable, CaseIterable, Identifiable {
    case breakfast = "Breakfast", lunch = "Lunch", dinner = "Dinner", snacks = "Snacks"
    var id: String { rawValue }

    /// A sensible meal for a time of day.
    static func at(hour: Int) -> MealSlot {
        switch hour {
        case 4..<11: return .breakfast
        case 11..<16: return .lunch
        case 16..<22: return .dinner
        default: return .snacks
        }
    }
}

/// One food logged to a meal. Keeps a copy of the food so later database changes don't alter history.
struct MealEntry: Codable, Equatable, Identifiable {
    var id: String
    var day: String
    var slot: MealSlot
    var time: Int64
    var food: FoodItem
    var amount: Double
    var serving: Serving

    var nutrients: Nutrients { food.nutrients(amount: amount, serving: serving) }

    var amountText: String {
        let n = amount == amount.rounded() ? String(Int(amount)) : String(format: "%.2g", amount)
        return "\(n) \(serving.label)"
    }
}

enum MealAim: String, Codable, CaseIterable {
    case maintain = "Maintain", lose = "Lose slowly", gain = "Gain"

    var detail: String {
        switch self {
        case .maintain: return "Eat about what you burn"
        case .lose: return "About 300 to 500 cal a day under your usual burn"
        case .gain: return "About 250 cal a day over your usual burn"
        }
    }
}

enum MacroStyle: String, Codable, CaseIterable {
    case rings = "Rings", split = "Split ring", bars = "Bars"
}

struct MealSettings: Codable, Equatable {
    var setUp = false
    var aim: MealAim = .maintain
    var automatic = true
    var manualGoal: Int = 2000
    var avoid: [String] = []
    /// Macro targets: automatic from weight and aim, or the person's own split.
    var macrosAutomatic = true
    /// Own split in percent of calories: protein, carbs, fat. Always adds up to 100.
    var split: [Int] = [25, 45, 30]
    var macroStyle: MacroStyle = .rings

    init() {}

    // Missing keys fall back to defaults, so adding settings never wipes old ones.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = MealSettings()
        setUp = try c.decodeIfPresent(Bool.self, forKey: .setUp) ?? d.setUp
        aim = (try? c.decodeIfPresent(MealAim.self, forKey: .aim)) ?? d.aim
        automatic = try c.decodeIfPresent(Bool.self, forKey: .automatic) ?? d.automatic
        manualGoal = try c.decodeIfPresent(Int.self, forKey: .manualGoal) ?? d.manualGoal
        avoid = try c.decodeIfPresent([String].self, forKey: .avoid) ?? d.avoid
        macrosAutomatic = try c.decodeIfPresent(Bool.self, forKey: .macrosAutomatic) ?? d.macrosAutomatic
        let sp = try c.decodeIfPresent([Int].self, forKey: .split) ?? d.split
        split = sp.count == 3 && sp.reduce(0, +) == 100 ? sp : d.split
        macroStyle = (try? c.decodeIfPresent(MacroStyle.self, forKey: .macroStyle)) ?? d.macroStyle
    }
}

/// Daily macro targets in grams.
struct MacroTargets: Equatable {
    var protein: Int
    var carbs: Int
    var fat: Int
}

enum MacroMath {
    /// Automatic: protein from body weight and aim (1.6 g/kg when losing or gaining, 1.2 when maintaining),
    /// fat about 30% of calories, carbs the rest. Without a weight, protein is 25% of calories.
    static func automatic(calories: Int, weightKg: Double?, aim: MealAim) -> MacroTargets {
        let cal = Double(max(0, calories))
        let perKg: Double = aim == .maintain ? 1.2 : 1.6
        var protein = weightKg.map { $0 * perKg } ?? cal * 0.25 / 4
        protein = min(protein, cal * 0.4 / 4)
        let fat = cal * 0.30 / 9
        let carbs = max(0, (cal - protein * 4 - fat * 9) / 4)
        return MacroTargets(protein: Int(protein.rounded()), carbs: Int(carbs.rounded()), fat: Int(fat.rounded()))
    }

    /// Own split: percent of calories for protein, carbs and fat.
    static func fromSplit(calories: Int, split: [Int]) -> MacroTargets {
        let cal = Double(max(0, calories))
        let s = split.count == 3 ? split : [25, 45, 30]
        return MacroTargets(protein: Int((cal * Double(s[0]) / 100 / 4).rounded()),
                            carbs: Int((cal * Double(s[1]) / 100 / 4).rounded()),
                            fat: Int((cal * Double(s[2]) / 100 / 9).rounded()))
    }

    static func targets(calories: Int, weightKg: Double?, settings: MealSettings) -> MacroTargets {
        settings.macrosAutomatic ? automatic(calories: calories, weightKg: weightKg, aim: settings.aim)
            : fromSplit(calories: calories, split: settings.split)
    }

    /// Moves one share and spreads the difference over the other two so the total stays 100.
    static func adjust(_ split: [Int], index: Int, to value: Int) -> [Int] {
        var s = split.count == 3 ? split : [25, 45, 30]
        let v = min(90, max(5, value))
        let others = [0, 1, 2].filter { $0 != index }
        var rest = 100 - v
        let a = s[others[0]], b = s[others[1]]
        let first = a + b == 0 ? rest / 2 : Int((Double(rest) * Double(a) / Double(a + b)).rounded())
        s[index] = v
        s[others[0]] = max(5, min(rest - 5, first))
        rest -= s[others[0]]
        s[others[1]] = rest
        return s
    }
}

enum MealMath {
    static func round50(_ v: Double) -> Int { Int((v / 50).rounded()) * 50 }

    /// The automatic goal: usual burn adjusted for the aim, never below resting burn.
    static func goal(aim: MealAim, usualBurn: Double, restingBurn: Double) -> Int {
        let target: Double
        switch aim {
        case .maintain: target = usualBurn
        case .lose: target = usualBurn - min(500, max(300, usualBurn * 0.2))
        case .gain: target = usualBurn + 250
        }
        let floor = Int((restingBurn / 50).rounded(.up)) * 50
        return max(floor, round50(target))
    }

    /// Avoid-list items found in a food's name or ingredients. Matches whole words, ignoring case and accents.
    static func avoidMatches(_ food: FoodItem, avoid: [String]) -> [String] {
        func norm(_ s: String) -> String {
            s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        }
        let text = " " + norm([food.name, food.brand ?? "", food.ingredients ?? ""].joined(separator: " "))
            .map { $0.isLetter || $0.isNumber ? $0 : " " }
            .reduce(into: "") { $0.append($1) } + " "
        return avoid.filter { item in
            let words = norm(item).split { !($0.isLetter || $0.isNumber) }.joined(separator: " ")
            guard !words.isEmpty else { return false }
            return text.contains(" \(words) ") || text.contains(" \(words)s ") || text.contains(" \(words)es ")
        }
    }
}

/// Reads food search results from USDA FoodData Central and Open Food Facts.
enum FoodParse {
    private static func num(_ v: Any?) -> Double? {
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        if let s = v as? String { return Double(s) }
        if let n = v as? NSNumber { return n.doubleValue }
        return nil
    }

    private static func tidy(_ s: String) -> String {
        // USDA names come in capitals for some data types; make them readable.
        let t = s.trimmingCharacters(in: .whitespaces)
        guard t == t.uppercased(), t.contains(where: \.isLetter) else { return t }
        let lower = t.lowercased()
        return lower.prefix(1).uppercased() + lower.dropFirst()
    }

    /// USDA `/v1/foods/search` response. Nutrient values in search results are per 100 g.
    static func usda(_ data: Data) -> [FoodItem] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let foods = root["foods"] as? [[String: Any]] else { return [] }
        return foods.compactMap { f in
            guard let id = num(f["fdcId"]), let name = f["description"] as? String,
                  let list = f["foodNutrients"] as? [[String: Any]] else { return nil }
            var values: [String: Double] = [:]
            for n in list {
                guard let number = n["nutrientNumber"] as? String, let v = num(n["value"]) else { continue }
                if values[number] == nil { values[number] = v }
            }
            guard let kcal = values["208"] ?? values["957"] ?? values["958"] else { return nil }
            var servings: [Serving] = []
            for m in (f["foodMeasures"] as? [[String: Any]]) ?? [] {
                guard let text = m["disseminationText"] as? String, let g = num(m["gramWeight"]), g > 0,
                      text.lowercased() != "quantity not specified" else { continue }
                let s = Serving(label: "\(text) (\(Int(g.rounded())) g)", grams: g)
                if !servings.contains(s) { servings.append(s) }
                if servings.count >= 4 { break }
            }
            if let size = num(f["servingSize"]), size > 0, (f["servingSizeUnit"] as? String)?.lowercased().hasPrefix("g") == true {
                let label = (f["householdServingFullText"] as? String).map { "\($0) (\(Int(size.rounded())) g)" } ?? "serving (\(Int(size.rounded())) g)"
                servings.insert(Serving(label: label, grams: size), at: 0)
            }
            let brand = (f["brandName"] as? String) ?? (f["brandOwner"] as? String)
            return FoodItem(id: "usda:\(Int(id))", name: tidy(name), brand: brand.map(tidy), source: .usda,
                            per100g: Nutrients(kcal: kcal, protein: values["203"] ?? 0, carbs: values["205"] ?? 0, fat: values["204"] ?? 0),
                            servings: servings, ingredients: f["ingredients"] as? String)
        }
    }

    static func offProduct(_ p: [String: Any]) -> FoodItem? {
        guard let code = p["code"] as? String ?? (p["_id"] as? String),
              let name = (p["product_name"] as? String)?.trimmingCharacters(in: .whitespaces), !name.isEmpty,
              let n = p["nutriments"] as? [String: Any] else { return nil }
        let kcal = num(n["energy-kcal_100g"]) ?? num(n["energy_100g"]).map { $0 / 4.184 }
        guard let kcal else { return nil }
        var servings: [Serving] = []
        if let q = num(p["serving_quantity"]), q > 0 {
            let label = (p["serving_size"] as? String).map { "serving, \($0)" } ?? "serving (\(Int(q.rounded())) g)"
            servings.append(Serving(label: label, grams: q))
        }
        let brand = (p["brands"] as? String)?.split(separator: ",").first.map { $0.trimmingCharacters(in: .whitespaces) }
        return FoodItem(id: "off:\(code)", name: name, brand: brand?.isEmpty == false ? brand : nil, source: .openFoodFacts,
                        per100g: Nutrients(kcal: kcal, protein: num(n["proteins_100g"]) ?? 0, carbs: num(n["carbohydrates_100g"]) ?? 0, fat: num(n["fat_100g"]) ?? 0),
                        servings: servings, ingredients: p["ingredients_text"] as? String)
    }

    /// Open Food Facts search response.
    static func offSearch(_ data: Data) -> [FoodItem] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let products = root["products"] as? [[String: Any]] else { return [] }
        return products.compactMap(offProduct)
    }

    /// Open Food Facts single product (barcode) response.
    static func offBarcode(_ data: Data) -> FoodItem? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              num(root["status"]) == 1, let p = root["product"] as? [String: Any] else { return nil }
        var product = p
        if product["code"] == nil { product["code"] = root["code"] }
        return offProduct(product)
    }
}
