import Foundation
import Security

/// Meals, favorites and meal settings, kept in meals.json.
@MainActor
final class MealStore: ObservableObject {
    static let shared = MealStore()

    struct Saved: Codable {
        var settings = MealSettings()
        var entries: [MealEntry] = []
        var favorites: [FoodItem] = []
        var recents: [FoodItem] = []
    }

    @Published private(set) var data: Saved

    nonisolated static var url: URL { Store.shared.dir.appendingPathComponent("meals.json") }

    private init() {
        data = (try? JSONDecoder().decode(Saved.self, from: Data(contentsOf: Self.url))) ?? Saved()
    }

    var settings: MealSettings {
        get { data.settings }
        set { data.settings = newValue; save() }
    }

    func reload() {
        data = (try? JSONDecoder().decode(Saved.self, from: Data(contentsOf: Self.url))) ?? Saved()
    }

    private func save() { JSONFile.write(data, to: Self.url) }

    func entries(_ day: String) -> [MealEntry] { data.entries.filter { $0.day == day }.sorted { $0.time < $1.time } }

    func total(_ day: String) -> Nutrients { entries(day).reduce(.zero) { $0 + $1.nutrients } }

    func add(_ e: MealEntry) {
        data.entries.removeAll { $0.id == e.id }
        data.entries.append(e)
        data.recents.removeAll { $0.id == e.food.id }
        data.recents.insert(e.food, at: 0)
        if data.recents.count > 60 { data.recents.removeLast(data.recents.count - 60) }
        save()
    }

    func remove(_ id: String) {
        data.entries.removeAll { $0.id == id }
        save()
    }

    func isFavorite(_ food: FoodItem) -> Bool { data.favorites.contains { $0.id == food.id } }

    func toggleFavorite(_ food: FoodItem) {
        if isFavorite(food) { data.favorites.removeAll { $0.id == food.id } } else { data.favorites.insert(food, at: 0) }
        save()
    }

    /// Adds meals and favorites from a backup that are not already here.
    func merge(_ json: Data) {
        guard let incoming = try? JSONDecoder().decode(Saved.self, from: json) else { return }
        let ids = Set(data.entries.map(\.id))
        data.entries += incoming.entries.filter { !ids.contains($0.id) }
        let favs = Set(data.favorites.map(\.id))
        data.favorites += incoming.favorites.filter { !favs.contains($0.id) }
        if !data.settings.setUp && incoming.settings.setUp { data.settings = incoming.settings }
        save()
    }

    /// The automatic or manual daily goal, plus the numbers behind it.
    struct Goal { var calories: Int; var usualBurn: Double?; var restingBurn: Double? }

    nonisolated static func goal(settings: MealSettings, appSettings: AppSettings) -> Goal {
        let resting = appSettings.body.map { Metrics.bmrPerMinute($0) * 1440 }
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let from = cal.date(byAdding: .day, value: -28, to: today) ?? today
        let to = cal.date(byAdding: .day, value: -1, to: today) ?? today
        let burns = DayEngine.shared.records(from: from, to: to, settings: appSettings).compactMap(\.calories).filter { $0 > 800 }
        let usual = burns.count >= 5 ? burns.reduce(0, +) / Double(burns.count) : resting.map { $0 * 1.3 }
        guard settings.automatic, let u = usual else { return Goal(calories: settings.manualGoal, usualBurn: usual, restingBurn: resting) }
        return Goal(calories: MealMath.goal(aim: settings.aim, usualBurn: u, restingBurn: resting ?? 1200), usualBurn: u, restingBurn: resting)
    }
}

/// The USDA key lives in the phone's keychain, so it is never in backups or the app's files.
enum FoodKey {
    private static let account = "usda-key"

    static var value: String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: account,
                                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        let s = String(decoding: d, as: UTF8.self)
        return s.isEmpty ? nil : s
    }

    static func set(_ key: String?) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        guard let key = key?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(key.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }
}

/// Looks foods up online. Only the search words or barcode leave the phone.
enum FoodAPI {
    enum Failure: LocalizedError {
        case offline, limited, server
        var errorDescription: String? {
            switch self {
            case .offline: return "Couldn't reach the food database. Check your connection."
            case .limited: return "The food database is busy or you've hit the limit for now. Adding your free USDA key in Settings, Meals raises the limit."
            case .server: return "The food database had a problem. Try again in a moment."
            }
        }
    }

    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 15
        c.httpAdditionalHeaders = ["User-Agent": "Zdravlje/0.1 (personal iOS app)"]
        return URLSession(configuration: c)
    }()

    private static func get(_ url: URL) async throws -> Data {
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(from: url) } catch { throw Failure.offline }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 429 || code == 403 { throw Failure.limited }
        guard (200..<300).contains(code) else { throw code == 404 ? Failure.server : Failure.server }
        return data
    }

    static func usda(_ query: String) async throws -> [FoodItem] {
        var c = URLComponents(string: "https://api.nal.usda.gov/fdc/v1/foods/search")!
        c.queryItems = [
            .init(name: "query", value: query),
            .init(name: "pageSize", value: "15"),
            .init(name: "dataType", value: "Foundation,SR Legacy,Survey (FNDDS)"),
            .init(name: "api_key", value: FoodKey.value ?? "DEMO_KEY"),
        ]
        return FoodParse.usda(try await get(c.url!))
    }

    private static let offFields = "code,product_name,brands,nutriments,serving_size,serving_quantity,ingredients_text"

    static func packaged(_ query: String) async throws -> [FoodItem] {
        var c = URLComponents(string: "https://world.openfoodfacts.org/cgi/search.pl")!
        c.queryItems = [
            .init(name: "search_terms", value: query), .init(name: "search_simple", value: "1"),
            .init(name: "action", value: "process"), .init(name: "json", value: "1"),
            .init(name: "page_size", value: "8"), .init(name: "fields", value: offFields),
        ]
        return FoodParse.offSearch(try await get(c.url!))
    }

    static func barcode(_ code: String) async throws -> FoodItem? {
        let digits = code.filter(\.isNumber)
        guard !digits.isEmpty, let url = URL(string: "https://world.openfoodfacts.org/api/v2/product/\(digits).json?fields=\(offFields)") else { return nil }
        do {
            return FoodParse.offBarcode(try await get(url))
        } catch Failure.server {
            return nil
        }
    }
}
