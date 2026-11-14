import Foundation

/// One sleep-stage block. Times are Unix milliseconds.
struct BandStage: Codable, Equatable {
    enum Kind: String, Codable { case wake, light, deep, rem }
    var start: Int64
    var end: Int64
    var kind: Kind

    var minutes: Double { Double(end - start) / 60_000 }
}

/// What the band itself measured on one day, beyond the heart rate broadcast:
/// band-counted steps, breathing rate and sleep stages. Keyed by the day you
/// woke up, like DayRecord. Filled by the OpenStrap import now, and by
/// Zdravlje's own band link later.
struct BandDay: Codable, Equatable {
    var day: String
    var source: String
    var steps: Int?
    var respRate: Double?
    var restingHR: Double?
    var hrv: Double?
    var wornMin: Double?
    var stages: [BandStage]?

    /// Totals per stage, in minutes.
    var stageMinutes: [BandStage.Kind: Double] {
        var out: [BandStage.Kind: Double] = [:]
        for s in stages ?? [] { out[s.kind, default: 0] += s.minutes }
        return out
    }

    /// Fills in fields this day lacks from another record of the same day.
    func filling(from other: BandDay) -> BandDay {
        var r = self
        r.steps = r.steps ?? other.steps
        r.respRate = r.respRate ?? other.respRate
        r.restingHR = r.restingHR ?? other.restingHR
        r.hrv = r.hrv ?? other.hrv
        r.wornMin = r.wornMin ?? other.wornMin
        if (r.stages ?? []).isEmpty { r.stages = other.stages }
        return r
    }
}

struct BandHistoryData: Codable, Equatable {
    var days: [String: BandDay] = [:]
}

/// Reads an OpenStrap CSV export (daily, sleep). Only rows the band measured
/// are kept: OpenStrap's copy of WHOOP history is skipped, because Zdravlje
/// already has that from the WHOOP import.
enum OpenStrapImport {
    struct Result: Equatable {
        var data = BandHistoryData()
        var skippedWhoopRows = 0
        var foundDaily = false
        var foundSleep = false
    }

    private static func num(_ row: [String: String], _ key: String) -> Double? {
        row[key].flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }
    }

    static func parse(files: [String: Data]) -> Result {
        var out = Result()
        func file(_ part: String) -> Data? {
            files.first { $0.key.contains("openstrap_\(part)") && $0.key.hasSuffix(".csv") }?.value
        }
        if let daily = file("daily") {
            out.foundDaily = true
            for row in CSV.table(daily) {
                guard let day = row["date"], day.count == 10 else { continue }
                guard row["source"] == "band" else {
                    out.skippedWhoopRows += 1
                    continue
                }
                var d = out.data.days[day] ?? BandDay(day: day, source: "openstrap")
                d.steps = num(row, "steps").map { Int($0.rounded()) }
                d.respRate = num(row, "resp_rate")
                d.restingHR = num(row, "resting_hr")
                d.hrv = num(row, "hrv")
                d.wornMin = num(row, "worn_min")
                out.data.days[day] = d
            }
        }
        if let sleep = file("sleep") {
            out.foundSleep = true
            var byDay: [String: [BandStage]] = [:]
            for row in CSV.table(sleep) {
                // "unobserved" marks one-second gaps in coverage; not a stage.
                guard let day = row["date"], day.count == 10,
                      let kind = row["stage"].flatMap(BandStage.Kind.init(rawValue:)),
                      let s = num(row, "start_ts"), let e = num(row, "end_ts"), e > s else { continue }
                byDay[day, default: []].append(BandStage(start: Int64(s * 1000), end: Int64(e * 1000), kind: kind))
            }
            for (day, blocks) in byDay {
                var d = out.data.days[day] ?? BandDay(day: day, source: "openstrap")
                d.stages = merged(blocks.sorted { $0.start < $1.start })
                out.data.days[day] = d
            }
        }
        return out
    }

    /// Joins neighbouring blocks of the same stage (the export splits them at
    /// coverage gaps).
    static func merged(_ blocks: [BandStage]) -> [BandStage] {
        var out: [BandStage] = []
        for b in blocks {
            if var last = out.last, last.kind == b.kind, b.start - last.end <= 2_000 {
                last.end = max(last.end, b.end)
                out[out.count - 1] = last
            } else {
                out.append(b)
            }
        }
        return out
    }

    /// Adds days not present and fills gaps in days that are. Returns how many
    /// days were new or gained data.
    static func merge(_ incoming: BandHistoryData, into current: BandHistoryData) -> (BandHistoryData, changed: Int) {
        var result = current
        var changed = 0
        for (k, v) in incoming.days {
            if let existing = result.days[k] {
                let filled = existing.filling(from: v)
                if filled != existing { result.days[k] = filled; changed += 1 }
            } else {
                result.days[k] = v
                changed += 1
            }
        }
        return (result, changed)
    }
}

/// Night summaries from sleep stages. Wrist staging is an estimate, so stage
/// totals are shown as ranges rather than exact minutes.
enum StageMath {
    struct Range: Equatable {
        var low: Double
        var high: Double
    }

    /// How uncertain each stage is from a wrist band, as a share of the total,
    /// with a 15-minute floor. Deep is the hardest to call, light the easiest.
    /// Awake time is measured directly, so it has no range.
    static func range(_ kind: BandStage.Kind, minutes: Double) -> Range? {
        let share: Double
        switch kind {
        case .deep: share = 0.45
        case .rem: share = 0.35
        case .light: share = 0.2
        case .wake: return nil
        }
        let spread = max(15, minutes * share)
        return Range(low: max(0, minutes - spread), high: minutes + spread)
    }

    /// Longest run without a wake block, in minutes.
    static func longestStretch(_ stages: [BandStage]) -> Double {
        var best: Double = 0
        var runStart: Int64?
        var runEnd: Int64 = 0
        for s in stages {
            if s.kind == .wake {
                if let a = runStart { best = max(best, Double(runEnd - a) / 60_000) }
                runStart = nil
            } else {
                if runStart == nil { runStart = s.start }
                runEnd = s.end
            }
        }
        if let a = runStart { best = max(best, Double(runEnd - a) / 60_000) }
        return best
    }

    /// Wake blocks of at least 5 minutes between the first and last sleep.
    static func wakeUps(_ stages: [BandStage]) -> Int {
        guard let first = stages.firstIndex(where: { $0.kind != .wake }),
              let last = stages.lastIndex(where: { $0.kind != .wake }), first < last else { return 0 }
        return stages[first...last].filter { $0.kind == .wake && $0.minutes >= 5 }.count
    }

    /// The middle half of past values (25th to 75th percentile). Needs at least
    /// `minimum` values, otherwise nil.
    static func usualRange(_ values: [Double], minimum: Int = 5) -> Range? {
        guard values.count >= minimum else { return nil }
        let v = values.sorted()
        func at(_ q: Double) -> Double {
            let pos = q * Double(v.count - 1)
            let i = Int(pos)
            let frac = pos - Double(i)
            return i + 1 < v.count ? v[i] + (v[i + 1] - v[i]) * frac : v[i]
        }
        return Range(low: at(0.25), high: at(0.75))
    }

    /// Whether a value is clearly outside the usual range: beyond it by more
    /// than a quarter of the range's width (and at least 10 minutes).
    static func compare(_ value: Double, to usual: Range) -> Int {
        let margin = max(10, (usual.high - usual.low) / 4)
        if value > usual.high + margin { return 1 }
        if value < usual.low - margin { return -1 }
        return 0
    }
}
