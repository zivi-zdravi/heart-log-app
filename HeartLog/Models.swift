import Foundation

enum JSONFile {
    static func write<T: Encodable>(_ value: T, to url: URL) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

struct AppSettings: Codable, Equatable {
    var profileName = ""
    var maxHR = 180
    var restingForZones = 60
    var weightKg: Double?
    var heightCm: Double?
    var age: Int?
    var female: Bool?
    var lowBattery = 20

    init() {}

    // Missing keys fall back to defaults, so adding settings never wipes old ones.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        profileName = try c.decodeIfPresent(String.self, forKey: .profileName) ?? ""
        maxHR = try c.decodeIfPresent(Int.self, forKey: .maxHR) ?? 180
        restingForZones = try c.decodeIfPresent(Int.self, forKey: .restingForZones) ?? 60
        weightKg = try c.decodeIfPresent(Double.self, forKey: .weightKg)
        heightCm = try c.decodeIfPresent(Double.self, forKey: .heightCm)
        age = try c.decodeIfPresent(Int.self, forKey: .age)
        female = try c.decodeIfPresent(Bool.self, forKey: .female)
        lowBattery = try c.decodeIfPresent(Int.self, forKey: .lowBattery) ?? 20
    }

    var zoneBounds: [Int] { Metrics.zoneBounds(maxHR: maxHR, resting: restingForZones) }

    var body: Metrics.Body? {
        guard let kg = weightKg, let cm = heightCm, let age = age, let female = female, kg > 0, cm > 0, age > 0 else { return nil }
        return Metrics.Body(kg: kg, cm: cm, age: Double(age), female: female)
    }
}

final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()
    @Published var value: AppSettings { didSet { if value != oldValue { JSONFile.write(value, to: Self.url) } } }

    private static var url: URL { Store.shared.dir.appendingPathComponent("settings.json") }

    private init() {
        if let data = try? Data(contentsOf: Self.url), let saved = try? JSONDecoder().decode(AppSettings.self, from: data) {
            value = saved
        } else {
            var fresh = AppSettings()
            fresh.profileName = UserDefaults.standard.string(forKey: "profile") ?? ""
            value = fresh
        }
    }

    func reload() {
        if let data = try? Data(contentsOf: Self.url), let saved = try? JSONDecoder().decode(AppSettings.self, from: data) {
            value = saved
        }
    }
}

struct ActivityRecord: Codable, Identifiable, Equatable {
    var id: String
    var type: String
    var start: Int64
    var end: Int64?
    var dismissed: Bool?
}

final class ActivityStore: ObservableObject {
    static let shared = ActivityStore()
    static let types = ["Walking", "Cycling", "Running", "Hiking", "Strength", "Yoga", "Yard work", "Other"]

    @Published private(set) var all: [ActivityRecord] = []
    @Published var pendingStart = false

    private static var url: URL { Store.shared.dir.appendingPathComponent("activities.json") }

    private init() { load() }

    func load() {
        all = (try? JSONDecoder().decode([ActivityRecord].self, from: Data(contentsOf: Self.url))) ?? []
    }

    private func save() { JSONFile.write(all, to: Self.url) }

    var current: ActivityRecord? { all.first { $0.end == nil && $0.dismissed != true } }

    var saved: [ActivityRecord] {
        all.filter { $0.end != nil && $0.dismissed != true }.sorted { $0.start > $1.start }
    }

    func start(_ type: String) {
        guard current == nil else { return }
        let now = Store.nowMs()
        all.append(ActivityRecord(id: "a\(now)", type: type, start: now, end: nil, dismissed: nil))
        save()
    }

    func add(type: String, start: Int64, end: Int64, dismissed: Bool = false) {
        all.append(ActivityRecord(id: "a\(start)-\(Store.nowMs())", type: type, start: start, end: end, dismissed: dismissed ? true : nil))
        save()
    }

    func finish(_ id: String) { update(id) { $0.end = Store.nowMs() } }

    func update(_ id: String, _ change: (inout ActivityRecord) -> Void) {
        guard let i = all.firstIndex(where: { $0.id == id }) else { return }
        change(&all[i])
        save()
    }

    func remove(_ id: String) {
        all.removeAll { $0.id == id }
        save()
    }

    /// Adds records from a backup that are not already here. Local records always win.
    @discardableResult
    func merge(_ data: Data) -> Int {
        guard let incoming = try? JSONDecoder().decode([ActivityRecord].self, from: data) else { return 0 }
        let known = Set(all.map(\.id))
        let fresh = incoming.filter { !known.contains($0.id) }
        all += fresh
        save()
        return fresh.count
    }
}

enum Signing {
    /// When this install stops opening, read from the provisioning profile Sideloadly embeds.
    static let expiry: Date? = {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .isoLatin1),
              let a = text.range(of: "<?xml"), let b = text.range(of: "</plist>") else { return nil }
        let plist = Data(text[a.lowerBound..<b.upperBound].utf8)
        let dict = try? PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any]
        return dict?["ExpirationDate"] as? Date
    }()
}
