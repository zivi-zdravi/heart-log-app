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
    /// From OpenStrap imports.
    var days: [String: BandDay] = [:]
    /// Staged by Zdravlje itself from the band's own record. Wins over imports.
    var own: [String: BandDay]?

    /// What each day shows: Zdravlje's own stages first, imported values filling gaps.
    var combined: [String: BandDay] {
        var out = days
        for (k, v) in own ?? [:] { out[k] = days[k].map { v.filling(from: $0) } ?? v }
        return out
    }
}

/// Reads an OpenStrap CSV export (daily, sleep). Only rows the band measured
/// are kept: OpenStrap's copy of WHOOP history is skipped, because Zdravlje
/// already has that from the WHOOP import.
enum OpenStrapImport {
    struct Result: Equatable {
        var data = BandHistoryData()
        var skippedWhoopRows = 0
        /// Breathing rate from OpenStrap's copy of WHOOP history, by day.
        var whoopBreathing: [String: Double] = [:]
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
                    if row["source"] == "whoop_export", let r = num(row, "resp_rate") { out.whoopBreathing[day] = r }
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

    struct Night: Equatable {
        var start: Int64
        var end: Int64
        var asleepMin: Double
        var inBedMin: Double
    }

    /// The night as the stages describe it: from the first block to the final
    /// wake, in bed until the last block, asleep for every non-wake minute.
    /// Nil when there's no sleep at all.
    static func night(_ stages: [BandStage]) -> Night? {
        guard let first = stages.first, let last = stages.last,
              let finalSleep = stages.last(where: { $0.kind != .wake }), last.end > first.start else { return nil }
        let asleep = stages.filter { $0.kind != .wake }.reduce(0) { $0 + $1.minutes }
        // Ends at the final wake; time lying awake after it still counts as in bed.
        return Night(start: first.start, end: finalSleep.end, asleepMin: asleep, inBedMin: Double(last.end - first.start) / 60_000)
    }

    /// Applies a bedtime and wake time you set yourself: anything before you
    /// fell asleep or after you woke becomes awake, so the chart, the totals
    /// and the scores all follow your times.
    static func clip(_ stages: [BandStage], onset: Int64, wake: Int64) -> [BandStage] {
        guard wake > onset else { return stages }
        var out: [BandStage] = []
        for b in stages {
            var cuts = [b.start, b.end]
            if onset > b.start && onset < b.end { cuts.append(onset) }
            if wake > b.start && wake < b.end { cuts.append(wake) }
            cuts = Array(Set(cuts)).sorted()
            for i in 0..<(cuts.count - 1) {
                let a = cuts[i], z = cuts[i + 1]
                let outside = z <= onset || a >= wake
                out.append(BandStage(start: a, end: z, kind: outside ? .wake : b.kind))
            }
        }
        return OpenStrapImport.merged(out)
    }

    /// Minutes awake between falling asleep and the final wake, leaving out
    /// time before first sleep and after the last.
    static func awakeDuringSleep(_ stages: [BandStage]) -> Double {
        guard let first = stages.firstIndex(where: { $0.kind != .wake }),
              let last = stages.lastIndex(where: { $0.kind != .wake }), first < last else { return 0 }
        return stages[first...last].filter { $0.kind == .wake }.reduce(0) { $0 + $1.minutes }
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
    /// `minMargin` is in the value's own units (minutes by default).
    static func compare(_ value: Double, to usual: Range, minMargin: Double = 10) -> Int {
        let margin = max(minMargin, (usual.high - usual.low) / 4)
        if value > usual.high + margin { return 1 }
        if value < usual.low - margin { return -1 }
        return 0
    }
}

/// Phone use as an awake signal. Zdravlje logs "unlocked" and "locked" while
/// recording; time between them means you were awake, whatever the band says.
enum PhoneUse {
    struct Span: Equatable {
        var start: Int64
        var end: Int64
    }

    /// Minutes of sleep that must follow the night's last phone use for it to
    /// count as going back to sleep. Less than this, and picking up the phone
    /// is treated as the final wake. Tuned after a week of nights.
    static let backToSleepMinutes: Double = 20
    /// An unlock with no lock after it is capped at this length.
    static let openEndedCap: Int64 = 30 * 60_000

    /// Pairs each unlock with the next lock. Events are (time ms, type).
    static func spans(_ events: [(Int64, String)]) -> [Span] {
        var out: [Span] = []
        var open: Int64?
        for (t, type) in events.sorted(by: { $0.0 < $1.0 }) {
            if type == "unlocked" {
                if let o = open { out.append(Span(start: o, end: min(t, o + openEndedCap))) }
                open = t
            } else if type == "locked", let o = open {
                if t > o { out.append(Span(start: o, end: t)) }
                open = nil
            }
        }
        if let o = open { out.append(Span(start: o, end: o + openEndedCap)) }
        return out
    }

    /// Reads "ms,type,detail" event lines.
    static func parse(_ csv: String) -> [(Int64, String)] {
        csv.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(separator: ",", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count >= 2, let t = Int64(parts[0]) else { return nil }
            return (t, String(parts[1]))
        }
    }

    /// Marks phone use inside a night's stages as awake, and ends the night at
    /// the last phone pickup when too little sleep follows it.
    static func apply(_ phone: [Span], to stages: [BandStage]) -> [BandStage] {
        guard let first = stages.first, let last = stages.last, !phone.isEmpty else { return stages }
        let inside = phone.filter { $0.end > first.start && $0.start < last.end }
        guard !inside.isEmpty else { return stages }
        // Split blocks at phone edges; overlapping pieces become wake.
        var out: [BandStage] = []
        for b in stages {
            var cuts = [b.start, b.end]
            for p in inside {
                if p.start > b.start && p.start < b.end { cuts.append(p.start) }
                if p.end > b.start && p.end < b.end { cuts.append(p.end) }
            }
            cuts = Array(Set(cuts)).sorted()
            for i in 0..<(cuts.count - 1) {
                let a = cuts[i], z = cuts[i + 1]
                let onPhone = inside.contains { $0.start <= a && $0.end >= z }
                out.append(BandStage(start: a, end: z, kind: onPhone ? .wake : b.kind))
            }
        }
        // Final wake: too little sleep after the last phone use.
        if let lastUse = inside.max(by: { $0.start < $1.start }) {
            let after = out.filter { $0.start >= lastUse.end && $0.kind != .wake }.reduce(0) { $0 + $1.minutes }
            if after < backToSleepMinutes {
                out = out.map { $0.start >= lastUse.start ? BandStage(start: $0.start, end: $0.end, kind: .wake) : $0 }
            }
        }
        return OpenStrapImport.merged(out)
    }

    /// The same rules for a night found from heart rate only (no stages).
    static func apply(_ phone: [Span], to p: SleepPeriod) -> SleepPeriod {
        let inside = phone.filter { $0.end > p.onset && $0.start < p.wake }
        guard !inside.isEmpty else { return p }
        var r = p
        var wake = p.wake
        if let lastUse = inside.max(by: { $0.start < $1.start }),
           Double(p.wake - lastUse.end) / 60_000 < backToSleepMinutes {
            wake = lastUse.start
        }
        let awakeOnPhone = inside.reduce(0.0) { sum, s in
            let a = max(s.start, p.onset), z = min(s.end, wake)
            return z > a ? sum + Double(z - a) / 60_000 : sum
        }
        let cutTail = Double(p.wake - wake) / 60_000
        r.wake = wake
        r.asleepMin = max(0, p.asleepMin - awakeOnPhone - cutTail)
        return r
    }
}
