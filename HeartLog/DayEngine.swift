import Foundation

/// Imported WHOOP history, kept on this phone in history.json.
final class HistoryStore {
    static let shared = HistoryStore()
    private let lock = NSLock()
    private var data: HistoryData

    private static var url: URL { Store.shared.dir.appendingPathComponent("history.json") }

    private init() {
        data = (try? JSONDecoder().decode(HistoryData.self, from: Data(contentsOf: Self.url))) ?? HistoryData()
    }

    var days: [String: DayRecord] { lock.lock(); defer { lock.unlock() }; return data.days }
    var workouts: [ImportedWorkout] { lock.lock(); defer { lock.unlock() }; return data.workouts }

    func reload() {
        let fresh = (try? JSONDecoder().decode(HistoryData.self, from: Data(contentsOf: Self.url))) ?? HistoryData()
        lock.lock()
        data = fresh
        lock.unlock()
        DayEngine.shared.invalidateAll()
    }

    /// Adds days and workouts not already imported. Returns how many days were new.
    @discardableResult
    func merge(_ incoming: HistoryData) -> Int {
        lock.lock()
        let (merged, added) = HistoryImport.merge(incoming, into: data)
        data = merged
        JSONFile.write(merged, to: Self.url)
        lock.unlock()
        DayEngine.shared.invalidateAll()
        return added
    }

    /// Merges history.json from a backup.
    @discardableResult
    func merge(json: Data) -> Int {
        guard let incoming = try? JSONDecoder().decode(HistoryData.self, from: json) else { return 0 }
        return merge(incoming)
    }
}

/// Bedtimes and wake times the person set by hand, keyed by the day they woke up.
enum Overrides {
    struct Window: Codable, Equatable { var onset: Int64; var wake: Int64 }

    private static var url: URL { Store.shared.dir.appendingPathComponent("overrides.json") }
    private static let lock = NSLock()

    static func all() -> [String: Window] {
        lock.lock(); defer { lock.unlock() }
        return (try? JSONDecoder().decode([String: Window].self, from: Data(contentsOf: url))) ?? [:]
    }

    static func set(_ key: String, _ window: Window?) {
        lock.lock()
        var list = (try? JSONDecoder().decode([String: Window].self, from: Data(contentsOf: url))) ?? [:]
        list[key] = window
        JSONFile.write(list, to: url)
        lock.unlock()
        DayEngine.shared.invalidate(from: key)
    }

    /// Adds windows from a backup that are not already set here.
    static func merge(_ data: Data) {
        guard let incoming = try? JSONDecoder().decode([String: Window].self, from: data) else { return }
        lock.lock()
        var list = (try? JSONDecoder().decode([String: Window].self, from: Data(contentsOf: url))) ?? [:]
        for (k, v) in incoming where list[k] == nil { list[k] = v }
        JSONFile.write(list, to: url)
        lock.unlock()
        DayEngine.shared.invalidateAll()
    }
}

/// Works out each day's sleep, recovery and strain. Days the band recorded are calculated here;
/// earlier days come from WHOOP history. Finished days are cached in days.json.
final class DayEngine {
    static let shared = DayEngine()
    static let version = 1

    private struct Cache: Codable {
        var fingerprint = ""
        var days: [String: DayRecord] = [:]
    }

    private let lock = NSRecursiveLock()
    private var cache: Cache
    private var live: [String: (at: Int64, record: DayRecord)] = [:]
    private let calendar = Calendar.current
    private static var url: URL { Store.shared.dir.appendingPathComponent("days.json") }

    private init() {
        cache = (try? JSONDecoder().decode(Cache.self, from: Data(contentsOf: Self.url))) ?? Cache()
    }

    func key(_ day: Date) -> String { HistoryImport.dayKey(day, calendar: calendar) }

    func invalidateAll() {
        lock.lock(); defer { lock.unlock() }
        cache.days = [:]
        live = [:]
        save()
    }

    /// A changed night also changes the days after it (consistency, debt and usual values).
    func invalidate(from key: String) {
        lock.lock(); defer { lock.unlock() }
        cache.days = cache.days.filter { $0.key < key }
        live = [:]
        save()
    }

    private func save() { JSONFile.write(cache, to: Self.url) }

    private func fingerprint(_ s: AppSettings) -> String {
        let b = s.body.map { "\($0.kg),\($0.cm),\($0.age),\($0.female)" } ?? "none"
        return "\(Self.version)|\(s.maxHR)|\(s.restingForZones)|\(b)"
    }

    private func ms(_ d: Date) -> Int64 { Int64(d.timeIntervalSince1970 * 1000) }

    private func firstAppDay() -> Date? {
        let first = Store.shared.sessions().compactMap { Int64($0.dropFirst()) }.min()
        return first.map { calendar.startOfDay(for: Date(timeIntervalSince1970: Double($0) / 1000)) }
    }

    /// The stored numbers for a day, without filling in usual values.
    private func raw(_ k: String) -> DayRecord? {
        if let r = cache.days[k] ?? live[k]?.record, r.source == "app" { return r }
        return HistoryStore.shared.days[k]
    }

    /// The day's full record, or nil when there is nothing for that day.
    func record(_ day: Date, settings: AppSettings) -> DayRecord? {
        lock.lock(); defer { lock.unlock() }
        let fp = fingerprint(settings)
        if cache.fingerprint != fp {
            cache = Cache(fingerprint: fp, days: [:])
            live = [:]
        }
        let start = calendar.startOfDay(for: day)
        let k = key(start)
        if let first = firstAppDay(), start >= first {
            // Work forward from the first recorded day so each day can lean on the one before.
            var d = first
            var changed = false
            while d <= start {
                changed = compute(d, settings: settings) || changed
                guard let next = calendar.date(byAdding: .day, value: 1, to: d) else { break }
                d = next
            }
            if changed { save() }
            if let r = cache.days[k] ?? live[k]?.record, r.source == "app" { return r }
        }
        guard var r = HistoryStore.shared.days[k] else { return nil }
        fillUsual(&r, start)
        return r
    }

    /// Calculates one recorded day if it is not cached. Returns true when the cache changed.
    private func compute(_ start: Date, settings: AppSettings) -> Bool {
        let k = key(start)
        if cache.days[k] != nil { return false }
        let now = Store.nowMs()
        if let l = live[k], now - l.at < 60_000 { return false }
        let hour: Int64 = 3_600_000
        let s0 = ms(start)
        let dayEnd = ms(calendar.date(byAdding: .day, value: 1, to: start) ?? start)
        let finished = now > dayEnd + hour
        let samples = Store.shared.readSamples(from: s0 - 6 * hour, to: min(dayEnd, now))
        var r = DayRecord(day: k, source: "none")
        if samples.count >= 600 {
            r = calculate(k, start: start, s0: s0, dayEnd: min(dayEnd, now), samples: samples, settings: settings)
        }
        if finished {
            cache.days[k] = r
            return true
        }
        live[k] = (now, r)
        return false
    }

    private func calculate(_ k: String, start: Date, s0: Int64, dayEnd: Int64, samples: [Sample], settings: AppSettings) -> DayRecord {
        let hour: Int64 = 3_600_000
        var r = DayRecord(day: k, source: "app")
        let night = samples.filter { $0.t < s0 + 14 * hour }
        if let o = Overrides.all()[k] {
            r.sleep = SleepMath.period(night, onset: o.onset, wake: o.wake)
        } else {
            r.sleep = SleepMath.detect(night)
        }
        let day = samples.filter { $0.t >= s0 }
        let bounds = settings.zoneBounds
        r.strain = Metrics.strain(zoneSeconds: Metrics.zoneSeconds(day, bounds))
        if let body = settings.body, let first = day.first {
            r.calories = Metrics.calories(day, body: body, bounds: bounds, elapsedMinutes: Double(dayEnd - min(first.t, s0)) / 60_000)
        }
        if let p = r.sleep {
            let inside = samples.filter { $0.t >= p.onset && $0.t < p.wake }
            r.hrv = Metrics.hrv(inside)
            r.rhr = p.lowestHR
        } else {
            r.hrv = Metrics.hrv(samples.filter { $0.t >= s0 + 2 * hour && $0.t < s0 + 6 * hour })
            r.rhr = Metrics.restingHR(samples.filter { $0.t >= s0 && $0.t < s0 + 8 * hour })
        }

        let previous = (1...30).compactMap { calendar.date(byAdding: .day, value: -$0, to: start).flatMap { raw(key($0)) } }
        let base = SleepMath.median(previous.filter(\.isWhoop).compactMap(\.sleepNeedMin))
            ?? SleepMath.median(HistoryStore.shared.days.values.compactMap(\.sleepNeedMin)) ?? 460
        let yesterday = calendar.date(byAdding: .day, value: -1, to: start).flatMap { raw(key($0)) }
        let need = SleepMath.sleepNeed(base: base, prevStrain: yesterday?.strain, prevDebt: yesterday?.debtMin)
        r.sleepNeedMin = need
        if let p = r.sleep {
            r.debtMin = max(0, need - p.asleepMin)
            let earlier = (1...4).compactMap { calendar.date(byAdding: .day, value: -$0, to: start).flatMap { raw(key($0))?.sleep } }
            r.consistency = SleepMath.consistency(p, previous: earlier, calendar: calendar) ?? 75
            r.sleepScore = SleepMath.score(asleepMin: p.asleepMin, needMin: need, consistency: r.consistency ?? 75, efficiency: p.efficiency)
        }
        fillUsual(&r, start)
        if let h = r.hrv, let u = r.usualHRV, let sc = r.sleepScore, u > 0, h > 0 {
            r.recovery = SleepMath.recovery(hrv: h, usualHRV: u, sleepScore: sc)
        }
        return r
    }

    /// Usual values are medians of the previous 30 days, WHOOP history included.
    private func fillUsual(_ r: inout DayRecord, _ start: Date) {
        let previous = (1...30).compactMap { calendar.date(byAdding: .day, value: -$0, to: start).flatMap { raw(key($0)) } }
        func usual(_ v: [Double]) -> Double? { v.count >= 5 ? SleepMath.median(v) : nil }
        r.usualHRV = usual(previous.compactMap(\.hrv))
        r.usualRHR = usual(previous.compactMap { $0.rhr.map { Double($0) } })
        r.usualSleep = usual(previous.compactMap(\.sleepScore))
    }

    /// Records for a run of days, oldest first. Days with nothing are left out.
    func records(from: Date, to: Date, settings: AppSettings) -> [DayRecord] {
        var out: [DayRecord] = []
        var d = calendar.startOfDay(for: from)
        let end = calendar.startOfDay(for: to)
        while d <= end {
            if let r = record(d, settings: settings) { out.append(r) }
            guard let next = calendar.date(byAdding: .day, value: 1, to: d) else { break }
            d = next
        }
        return out
    }
}
