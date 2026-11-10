import Foundation

struct SleepPeriod: Codable, Equatable {
    var onset: Int64
    var wake: Int64
    var asleepMin: Double
    var inBedMin: Double
    var awakeEvents: Int?
    var lowestHR: Int?

    var efficiency: Double { inBedMin > 0 ? min(100, asleepMin / inBedMin * 100) : 0 }
}

/// One day's numbers, either calculated by this app or imported from WHOOP history.
struct DayRecord: Codable, Equatable {
    var day: String
    var source: String
    var version: Int = 1
    var sleep: SleepPeriod?
    var sleepNeedMin: Double?
    var debtMin: Double?
    var consistency: Double?
    var sleepScore: Double?
    var hrv: Double?
    var rhr: Int?
    var recovery: Double?
    var strain: Double?
    var calories: Double?
    var usualHRV: Double?
    var usualRHR: Double?
    var usualSleep: Double?

    var isWhoop: Bool { source == "whoop" }
}

/// Sleep detection and scoring from heart rate. Formulas were fitted to a year of WHOOP history;
/// every result is an estimate.
enum SleepMath {
    enum Level { case low, mid, high }

    static func level(_ value: Double) -> Level { value >= 67 ? .high : value >= 34 ? .mid : .low }

    static func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { min(hi, max(lo, v)) }

    static func median(_ v: [Double]) -> Double? {
        guard !v.isEmpty else { return nil }
        let s = v.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    static func percentile(_ v: [Double], _ p: Double) -> Double {
        let s = v.sorted()
        return s[Int(Double(s.count - 1) * p)]
    }

    /// Average heart rate per minute, for minutes with at least 20 readings.
    static func minuteAverages(_ s: [Sample]) -> [Int64: Double] {
        var acc: [Int64: (sum: Int, n: Int)] = [:]
        for x in s where x.hr > 0 {
            let v = acc[x.t / 60_000] ?? (0, 0)
            acc[x.t / 60_000] = (v.sum + x.hr, v.n + 1)
        }
        var out: [Int64: Double] = [:]
        for (m, v) in acc where v.n >= 20 { out[m] = Double(v.sum) / Double(v.n) }
        return out
    }

    static func threshold(_ avg: [Int64: Double]) -> Double? {
        guard avg.count >= 180 else { return nil }
        let values = Array(avg.values)
        let lo = percentile(values, 0.1)
        let hi = percentile(values, 0.8)
        return lo + max(6, 0.3 * (hi - lo))
    }

    /// Finds the longest stretch of low, settled heart rate, allowing breaks of up to 45 minutes.
    static func detect(_ s: [Sample]) -> SleepPeriod? {
        let avg = minuteAverages(s)
        guard let t = threshold(avg), let first = avg.keys.min(), let last = avg.keys.max() else { return nil }
        var smooth: [Int64: Double] = [:]
        for m in avg.keys {
            smooth[m] = median((m - 7...m + 7).compactMap { avg[$0] })
        }
        var best: (start: Int64, end: Int64, count: Int)?
        var current: (start: Int64, end: Int64, count: Int)?
        var gap = 0
        for m in first...last {
            if let v = smooth[m], v <= t {
                if current == nil { current = (m, m, 0) }
                current!.end = m
                current!.count += 1
                gap = 0
            } else if let c = current {
                gap += 1
                if gap > 45 {
                    if best == nil || c.count > best!.count { best = c }
                    current = nil
                    gap = 0
                }
            }
        }
        if let c = current, best == nil || c.count > best!.count { best = c }
        guard let b = best, b.count >= 120 else { return nil }
        // Heart rate keeps falling through the night, so the core block starts late.
        // Extend it outward while heart rate stays settled, allowing breaks of up to 10 minutes.
        let values = Array(avg.values)
        let lo = percentile(values, 0.1)
        let loose = max(t + 3, lo + 0.5 * (percentile(values, 0.8) - lo))
        func extend(from edge: Int64, step: Int64, limit: Int64) -> Int64 {
            var result = edge
            var m = edge + step
            var misses = 0
            while (step < 0 ? m >= limit : m <= limit) {
                if let v = smooth[m], v <= loose {
                    result = m
                    misses = 0
                } else {
                    misses += 1
                    if misses > 10 { break }
                }
                m += step
            }
            return result
        }
        let onset = extend(from: b.start, step: -1, limit: first)
        let wake = extend(from: b.end, step: 1, limit: last)
        return analyze(avg, onsetMinute: onset, wakeMinute: wake + 1, threshold: t, samples: s)
    }

    /// Scores a sleep window the person set by hand.
    static func period(_ s: [Sample], onset: Int64, wake: Int64) -> SleepPeriod {
        let avg = minuteAverages(s)
        let t = threshold(avg) ?? ((avg.values.min() ?? 50) + 10)
        let on = onset / 60_000
        return analyze(avg, onsetMinute: on, wakeMinute: max(on + 1, wake / 60_000), threshold: t, samples: s)
    }

    static func analyze(_ avg: [Int64: Double], onsetMinute: Int64, wakeMinute: Int64, threshold t: Double, samples: [Sample]) -> SleepPeriod {
        var awake = 0
        var events = 0
        var run = 0
        for m in onsetMinute..<wakeMinute {
            if let v = avg[m], v > t + 8 {
                awake += 1
                run += 1
            } else {
                if run >= 2 { events += 1 }
                run = 0
            }
        }
        if run >= 2 { events += 1 }
        let inBed = Double(wakeMinute - onsetMinute)
        let inside = samples.filter { $0.t >= onsetMinute * 60_000 && $0.t < wakeMinute * 60_000 }
        return SleepPeriod(onset: onsetMinute * 60_000, wake: wakeMinute * 60_000, asleepMin: max(0, inBed - Double(awake)),
                           inBedMin: inBed, awakeEvents: events, lowestHR: Metrics.restingHR(inside))
    }

    static func minuteOfDay(_ ms: Int64, shift: Int, calendar: Calendar) -> Double {
        let c = calendar.dateComponents([.hour, .minute], from: Date(timeIntervalSince1970: Double(ms) / 1000))
        return Double(((c.hour ?? 0) * 60 + (c.minute ?? 0) + shift) % 1440)
    }

    /// How closely bed and wake times match the previous nights.
    static func consistency(_ p: SleepPeriod, previous: [SleepPeriod], calendar: Calendar = .current) -> Double? {
        guard !previous.isEmpty else { return nil }
        func diff(_ a: Double, _ b: Double) -> Double { let d = abs(a - b); return min(d, 1440 - d) }
        var diffs: [Double] = []
        for q in previous {
            diffs.append(diff(minuteOfDay(p.onset, shift: 720, calendar: calendar), minuteOfDay(q.onset, shift: 720, calendar: calendar)))
            diffs.append(diff(minuteOfDay(p.wake, shift: 0, calendar: calendar), minuteOfDay(q.wake, shift: 0, calendar: calendar)))
        }
        let dev = diffs.reduce(0, +) / Double(diffs.count)
        return clamp(162.78 - 21.71 * log(1 + dev), 0, 100)
    }

    static func sleepNeed(base: Double, prevStrain: Double?, prevDebt: Double?) -> Double {
        base + max(0, (prevStrain ?? 0) - 10) * 4 + min(60, (prevDebt ?? 0) * 0.5)
    }

    static func score(asleepMin: Double, needMin: Double, consistency: Double, efficiency: Double) -> Double {
        let hours = min(100, asleepMin / max(1, needMin) * 100)
        return clamp(0.4802 * hours + 0.2945 * consistency + 0.663 * efficiency - 43.29, 0, 100)
    }

    static func recovery(hrv: Double, usualHRV: Double, sleepScore: Double) -> Double {
        clamp(60.55 * log(hrv / usualHRV) + 0.532 * sleepScore + 21.35, 1, 99)
    }

    /// The most strain that suits a day's recovery.
    static func strainTarget(recovery: Double) -> Double { 8 + recovery * 0.1 }
}
