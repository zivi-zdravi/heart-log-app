import Foundation

struct ImportedWorkout: Codable, Equatable, Identifiable {
    var start: Int64
    var end: Int64
    var type: String
    var strain: Double?
    var calories: Double?
    var avgHR: Int?
    var maxHR: Int?
    var zones: [Double]?

    var id: Int64 { start }
}

struct HistoryData: Codable, Equatable {
    var days: [String: DayRecord] = [:]
    var workouts: [ImportedWorkout] = []
}

/// Turns a WHOOP data export into daily records. Each day is keyed by the date you woke up.
enum HistoryImport {
    static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static func timeZone(_ text: String?) -> TimeZone {
        guard let t = text?.replacingOccurrences(of: "UTC", with: ""), !t.isEmpty else { return TimeZone(secondsFromGMT: 0)! }
        let sign = t.hasPrefix("-") ? -1 : 1
        let parts = t.dropFirst().split(separator: ":").compactMap { Int($0) }
        let seconds = sign * ((parts.first ?? 0) * 3600 + (parts.count > 1 ? parts[1] * 60 : 0))
        return TimeZone(secondsFromGMT: seconds) ?? TimeZone(secondsFromGMT: 0)!
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    static func date(_ text: String?, _ tz: TimeZone) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        formatter.timeZone = tz
        return formatter.date(from: text)
    }

    private static func num(_ row: [String: String], _ key: String) -> Double? {
        row[key].flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }
    }

    private static func ms(_ d: Date) -> Int64 { Int64(d.timeIntervalSince1970 * 1000) }

    static func parse(files: [String: Data], calendar: Calendar) -> HistoryData {
        func file(_ suffix: String) -> Data? { files.first { $0.key.hasSuffix(suffix) }?.value }
        var out = HistoryData()
        if let cycles = file("physiological_cycles.csv") {
            for row in CSV.table(cycles) {
                let tz = timeZone(row["Cycle timezone"])
                guard let start = date(row["Cycle start time"], tz) else { continue }
                let onset = date(row["Sleep onset"], tz)
                let wake = date(row["Wake onset"], tz)
                let key = dayKey(wake ?? start, calendar: calendar)
                var r = DayRecord(day: key, source: "whoop")
                r.recovery = num(row, "Recovery score %")
                r.hrv = num(row, "Heart rate variability (ms)")
                r.rhr = num(row, "Resting heart rate (bpm)").map { Int($0.rounded()) }
                r.strain = num(row, "Day Strain")
                r.calories = num(row, "Energy burned (cal)")
                r.sleepScore = num(row, "Sleep performance %")
                r.sleepNeedMin = num(row, "Sleep need (min)")
                r.debtMin = num(row, "Sleep debt (min)")
                r.consistency = num(row, "Sleep consistency %")
                if let o = onset, let w = wake, w > o {
                    let span = w.timeIntervalSince(o) / 60
                    r.sleep = SleepPeriod(onset: ms(o), wake: ms(w), asleepMin: num(row, "Asleep duration (min)") ?? span,
                                          inBedMin: num(row, "In bed duration (min)") ?? span, awakeEvents: nil, lowestHR: nil)
                }
                if let existing = out.days[key], (existing.sleep?.asleepMin ?? 0) >= (r.sleep?.asleepMin ?? 0) { continue }
                out.days[key] = r
            }
        }
        if let workouts = file("workouts.csv") {
            for row in CSV.table(workouts) {
                let tz = timeZone(row["Cycle timezone"])
                guard let s = date(row["Workout start time"], tz), let e = date(row["Workout end time"], tz) else { continue }
                let zones = (1...5).map { num(row, "HR Zone \($0) %") ?? 0 }
                out.workouts.append(ImportedWorkout(start: ms(s), end: ms(e), type: row["Activity name"] ?? "Activity",
                                                    strain: num(row, "Activity Strain"), calories: num(row, "Energy burned (cal)"),
                                                    avgHR: num(row, "Average HR (bpm)").map { Int($0) }, maxHR: num(row, "Max HR (bpm)").map { Int($0) },
                                                    zones: zones))
            }
            out.workouts.sort { $0.start > $1.start }
        }
        return out
    }

    /// Adds days and workouts not already present. Existing ones are kept.
    static func merge(_ incoming: HistoryData, into current: HistoryData) -> (HistoryData, added: Int) {
        var result = current
        var added = 0
        for (k, v) in incoming.days where result.days[k] == nil {
            result.days[k] = v
            added += 1
        }
        let known = Set(result.workouts.map(\.start))
        result.workouts += incoming.workouts.filter { !known.contains($0.start) }
        result.workouts.sort { $0.start > $1.start }
        return (result, added)
    }
}
