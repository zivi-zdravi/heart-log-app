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
    var cycleSymptoms: [String] = CycleMath.defaultSymptoms
    var includeInAsk = true

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = BodySettings()
        bloodPressure = try c.decodeIfPresent(Bool.self, forKey: .bloodPressure) ?? d.bloodPressure
        cycle = try c.decodeIfPresent(Bool.self, forKey: .cycle) ?? d.cycle
        menopause = try c.decodeIfPresent(Bool.self, forKey: .menopause) ?? d.menopause
        symptoms = try c.decodeIfPresent([String].self, forKey: .symptoms) ?? d.symptoms
        cycleSymptoms = try c.decodeIfPresent([String].self, forKey: .cycleSymptoms) ?? d.cycleSymptoms
        includeInAsk = try c.decodeIfPresent(Bool.self, forKey: .includeInAsk) ?? d.includeInAsk
    }

    var anyOn: Bool { bloodPressure || cycle || menopause }
    var countOn: Int { [bloodPressure, cycle, menopause].filter { $0 }.count }
}

/// One time a symptom happened (a hot flash, a night sweat). The time is kept so it
/// can be lined up with sleep and heart rate.
struct SymptomEvent: Codable, Equatable, Identifiable {
    var id: String
    var time: Int64
    var name: String
}

struct BodyData: Codable, Equatable {
    var settings = BodySettings()
    var bp: [BPReading] = []
    var events: [SymptomEvent] = []
    /// How bad a symptom was on a day, 0 to 3. Keyed by day ("2026-11-16"), then symptom.
    var ratings: [String: [String: Int]] = [:]
    /// Flow by day: 0 none, 1 spotting, 2 light, 3 medium, 4 heavy.
    var flow: [String: Int] = [:]
    /// Cycle symptoms by day.
    var cycleNotes: [String: [String]] = [:]

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        settings = try c.decodeIfPresent(BodySettings.self, forKey: .settings) ?? BodySettings()
        bp = try c.decodeIfPresent([BPReading].self, forKey: .bp) ?? []
        events = try c.decodeIfPresent([SymptomEvent].self, forKey: .events) ?? []
        ratings = try c.decodeIfPresent([String: [String: Int]].self, forKey: .ratings) ?? [:]
        flow = try c.decodeIfPresent([String: Int].self, forKey: .flow) ?? [:]
        cycleNotes = try c.decodeIfPresent([String: [String]].self, forKey: .cycleNotes) ?? [:]
    }

    mutating func addEvent(_ e: SymptomEvent) {
        events.removeAll { $0.id == e.id }
        events.append(e)
        events.sort { $0.time > $1.time }
    }

    mutating func rate(_ name: String, day: String, level: Int?) {
        var d = ratings[day] ?? [:]
        d[name] = level.map { min(3, max(0, $0)) }
        ratings[day] = d.isEmpty ? nil : d
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
        let haveEvents = Set(events.map(\.id))
        let newEvents = other.events.filter { !haveEvents.contains($0.id) }
        events = (events + newEvents).sorted { $0.time > $1.time }
        for (day, levels) in other.ratings {
            for (name, level) in levels where ratings[day]?[name] == nil { ratings[day, default: [:]][name] = level }
        }
        var added = new.count + newEvents.count
        for (day, f) in other.flow where flow[day] == nil {
            flow[day] = f
            added += 1
        }
        for (day, notes) in other.cycleNotes where cycleNotes[day] == nil { cycleNotes[day] = notes }
        return added
    }
}

enum BodyMath {
    static let defaultSymptoms = ["Hot flashes", "Night sweats", "Sleep disruption", "Joint aches"]
    static let allSymptoms = defaultSymptoms + ["Brain fog", "Mood", "Headache", "Heart palpitations"]
    /// Symptoms logged each time they happen. The rest get a 0 to 3 rating for the day.
    static let counted: Set<String> = ["Hot flashes", "Night sweats", "Heart palpitations"]
    static let levels = ["none", "mild", "noticeable", "bad"]

    /// One of a counted symptom, for "+1" buttons: "Hot flash", "Night sweat", "Palpitation".
    static func shortName(_ name: String) -> String {
        switch name {
        case "Hot flashes": return "Hot flash"
        case "Night sweats": return "Night sweat"
        case "Heart palpitations": return "Palpitation"
        default: return name
        }
    }

    /// Wording on quick-log chips.
    static func chipName(_ name: String) -> String { name == "Sleep disruption" ? "Slept badly" : name }

    /// A night sweat at 1 AM belongs to the night before that morning; one at 11 PM to the next morning.
    /// Returns the day key of the morning the night ends on.
    static func nightKey(_ t: Int64, calendar: Calendar) -> String {
        var d = Date(timeIntervalSince1970: Double(t) / 1000)
        if calendar.component(.hour, from: d) >= 18, let next = calendar.date(byAdding: .day, value: 1, to: d) { d = next }
        return HistoryImport.dayKey(d, calendar: calendar)
    }

    /// The three-hour stretch of the day when an event happens most, from at least 5 events.
    static func busiestHours(_ times: [Int64], calendar: Calendar) -> Int? {
        guard times.count >= 5 else { return nil }
        var hours = [Int](repeating: 0, count: 24)
        for t in times { hours[calendar.component(.hour, from: Date(timeIntervalSince1970: Double(t) / 1000))] += 1 }
        var best = 0
        var bestCount = -1
        for h in 0..<24 {
            let n: Int = hours[h] + hours[(h + 1) % 24] + hours[(h + 2) % 24]
            if n > bestCount {
                best = h
                bestCount = n
            }
        }
        return best
    }

    static func hourText(_ h: Int) -> String {
        let h = h % 24
        return h == 0 ? "midnight" : h == 12 ? "noon" : h < 12 ? "\(h) AM" : "\(h - 12) PM"
    }
    static let bpTags = ["Left arm", "Right arm", "After coffee", "After exercise"]

    enum Tracker: CaseIterable { case bloodPressure, cycle, menopause }

    /// The trackers offered first for someone's sex and age. The others stay reachable in Settings.
    static func suggested(female: Bool?, age: Int?) -> Set<Tracker> {
        guard let female else { return Set(Tracker.allCases) }
        if !female { return [.bloodPressure] }
        guard let age else { return Set(Tracker.allCases) }
        if age < 40 { return [.bloodPressure, .cycle] }
        if age < 55 { return Set(Tracker.allCases) }
        return [.bloodPressure, .menopause]
    }

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

/// Period and cycle predictions from the days a person logged.
enum CycleMath {
    static let defaultSymptoms = ["Cravings", "Cramps", "Bloating", "Breakout", "Breast tenderness", "Headache", "Fatigue", "Mood"]
    static let allSymptoms = defaultSymptoms + ["Back pain", "Nausea", "Trouble sleeping", "Discharge"]
    static let flowNames = ["None", "Spotting", "Light", "Medium", "Heavy"]

    static func key(_ d: Date, _ cal: Calendar) -> String { HistoryImport.dayKey(d, calendar: cal) }

    static func date(_ key: String, _ cal: Calendar) -> Date? {
        let p = key.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        return cal.date(from: DateComponents(year: p[0], month: p[1], day: p[2]))
    }

    static func days(_ a: Date, _ b: Date, _ cal: Calendar) -> Int {
        cal.dateComponents([.day], from: cal.startOfDay(for: a), to: cal.startOfDay(for: b)).day ?? 0
    }

    /// First days of each period: a day with light flow or more, with no period day in the 10 days before.
    /// Spotting alone doesn't start a period.
    static func starts(_ flow: [String: Int], _ cal: Calendar) -> [Date] {
        let periodDays = flow.filter { $0.value >= 2 }.keys.compactMap { date($0, cal) }.sorted()
        var out: [Date] = []
        var last: Date?
        for d in periodDays {
            if let l = last, days(l, d, cal) <= 10 {
                last = d
                continue
            }
            out.append(d)
            last = d
        }
        return out
    }

    /// Lengths between period starts, ignoring gaps that look like a missed log (under 15 or over 60 days).
    static func lengths(_ starts: [Date], _ cal: Calendar) -> [Int] {
        guard starts.count >= 2 else { return [] }
        return (1..<starts.count).map { days(starts[$0 - 1], starts[$0], cal) }.filter { (15...60).contains($0) }
    }

    struct Prediction: Equatable {
        var cycleDay: Int
        var shortest: Int
        var longest: Int
        var nextFrom: Date
        var nextTo: Date
        /// False while there are too few logged cycles and a typical 28 days is assumed.
        var fromHistory: Bool
    }

    /// Where today is in the cycle and when the next period likely starts, from the last 6 cycles.
    static func predict(_ flow: [String: Int], today: Date, _ cal: Calendar) -> Prediction? {
        let st = starts(flow, cal)
        guard let last = st.last, last <= today else { return nil }
        let recent = Array(lengths(st, cal).suffix(6))
        var lo = 26, hi = 30
        if recent.count >= 3 {
            lo = recent.min()!
            hi = recent.max()!
        } else if !recent.isEmpty {
            let avg = Int((Double(recent.reduce(0, +)) / Double(recent.count)).rounded())
            lo = avg - 2
            hi = avg + 2
        }
        var from = cal.date(byAdding: .day, value: lo, to: last) ?? last
        var to = cal.date(byAdding: .day, value: hi, to: last) ?? last
        // Late: move the window forward so it never sits in the past.
        if to < cal.startOfDay(for: today) {
            let shift = days(to, today, cal)
            from = cal.date(byAdding: .day, value: shift, to: from) ?? from
            to = cal.date(byAdding: .day, value: shift, to: to) ?? to
        }
        return Prediction(cycleDay: days(last, today, cal) + 1, shortest: lo, longest: hi, nextFrom: from, nextTo: to, fromHistory: recent.count >= 3)
    }

    /// Symptoms logged in the 5 days before a period in at least 3 of the last 5 cycles.
    static func beforePeriod(_ notes: [String: [String]], starts: [Date], _ cal: Calendar) -> [String] {
        let recent = Array(starts.suffix(5))
        guard recent.count >= 3 else { return [] }
        var hits: [String: Int] = [:]
        for s in recent {
            var seen = Set<String>()
            for i in 1...5 {
                if let d = cal.date(byAdding: .day, value: -i, to: s) { seen.formUnion(notes[key(d, cal)] ?? []) }
            }
            for n in seen { hits[n, default: 0] += 1 }
        }
        return hits.filter { $0.value >= 3 }.keys.sorted()
    }
}
