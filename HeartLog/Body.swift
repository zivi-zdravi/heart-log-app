import Foundation

/// One blood pressure reading, entered by hand.
struct BPReading: Codable, Equatable, Identifiable {
    var id: String
    var time: Int64
    var systolic: Int
    var diastolic: Int
    var pulse: Int?
    var tags: [String] = []
    var note: String?
}

/// Which body trackers this person uses. Each phone sets its own.
struct BodySettings: Codable, Equatable {
    var bloodPressure = false
    var cycle = false
    var menopause = false
    var symptoms: [String] = BodyMath.defaultSymptoms
    var includeInAsk = true

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = BodySettings()
        bloodPressure = try c.decodeIfPresent(Bool.self, forKey: .bloodPressure) ?? d.bloodPressure
        cycle = try c.decodeIfPresent(Bool.self, forKey: .cycle) ?? d.cycle
        menopause = try c.decodeIfPresent(Bool.self, forKey: .menopause) ?? d.menopause
        symptoms = try c.decodeIfPresent([String].self, forKey: .symptoms) ?? d.symptoms
        includeInAsk = try c.decodeIfPresent(Bool.self, forKey: .includeInAsk) ?? d.includeInAsk
    }

    var anyOn: Bool { bloodPressure || cycle || menopause }
    var countOn: Int { [bloodPressure, cycle, menopause].filter { $0 }.count }
}

struct BodyData: Codable, Equatable {
    var settings = BodySettings()
    var bp: [BPReading] = []

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        settings = try c.decodeIfPresent(BodySettings.self, forKey: .settings) ?? BodySettings()
        bp = try c.decodeIfPresent([BPReading].self, forKey: .bp) ?? []
    }

    /// Adds or replaces a reading, keeping the list newest first.
    mutating func save(_ r: BPReading) {
        bp.removeAll { $0.id == r.id }
        bp.append(r)
        bp.sort { $0.time > $1.time }
    }

    /// Adds readings from another copy (a backup) that this one doesn't have.
    mutating func merge(_ other: BodyData) -> Int {
        let have = Set(bp.map(\.id))
        let new = other.bp.filter { !have.contains($0.id) }
        bp = (bp + new).sorted { $0.time > $1.time }
        return new.count
    }
}

enum BodyMath {
    static let defaultSymptoms = ["Hot flashes", "Night sweats", "Sleep disruption", "Joint aches"]
    static let bpTags = ["Left arm", "Right arm", "After coffee", "After exercise"]

    /// A reading that could be real. Rejects typos like a missing digit or the numbers swapped.
    static func valid(systolic: Int, diastolic: Int, pulse: Int?) -> Bool {
        guard (60...260).contains(systolic), (30...160).contains(diastolic), systolic > diastolic else { return false }
        if let p = pulse { return (30...220).contains(p) }
        return true
    }

    static func text(_ r: BPReading) -> String { "\(r.systolic)/\(r.diastolic)" }

    /// Average of the readings, rounded.
    static func average(_ rs: [BPReading]) -> (systolic: Int, diastolic: Int)? {
        guard !rs.isEmpty else { return nil }
        let n = Double(rs.count)
        return (Int((Double(rs.map(\.systolic).reduce(0, +)) / n).rounded()),
                Int((Double(rs.map(\.diastolic).reduce(0, +)) / n).rounded()))
    }

    /// Readings from the last `days` days, counting back from `now`.
    static func recent(_ rs: [BPReading], days: Int, now: Int64) -> [BPReading] {
        let from = now - Int64(days) * 86_400_000
        return rs.filter { $0.time >= from && $0.time <= now }
    }

    /// "this morning", "this afternoon", "this evening", "yesterday" or the date.
    static func when(_ t: Int64, now: Date, calendar: Calendar) -> String {
        let d = Date(timeIntervalSince1970: Double(t) / 1000)
        if calendar.isDate(d, inSameDayAs: now) {
            let h = calendar.component(.hour, from: d)
            return h < 12 ? "this morning" : h < 17 ? "this afternoon" : "this evening"
        }
        if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(d, inSameDayAs: y) { return "yesterday" }
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.setLocalizedDateFormatFromTemplate("MMMd")
        return f.string(from: d)
    }
}
