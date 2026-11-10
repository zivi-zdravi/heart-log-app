import Foundation

/// One heart rate reading. Times are milliseconds since 1970.
struct Sample {
    let t: Int64
    let hr: Int
    let rr: [Int]
}

/// Pure calculations on raw readings, so they can be re-run on old data.
/// Every score here is an estimate, not a medical measurement.
enum Metrics {
    static let gapMs: Int64 = 10_000

    struct Span: Equatable, Hashable {
        let start: Int64
        let end: Int64
    }

    struct Body: Equatable {
        let kg: Double
        let cm: Double
        let age: Double
        let female: Bool
    }

    /// Zone lower bounds at 40, 60, 70, 80 and 90 percent of heart rate reserve.
    static func zoneBounds(maxHR: Int, resting: Int) -> [Int] {
        let reserve = Double(max(1, maxHR - resting))
        return [0.4, 0.6, 0.7, 0.8, 0.9].map { Int((Double(resting) + $0 * reserve).rounded()) }
    }

    static func zone(_ hr: Int, _ bounds: [Int]) -> Int {
        var z = 0
        for (i, b) in bounds.enumerated() where hr >= b { z = i + 1 }
        return z
    }

    /// Seconds spent in zones 0 to 5. Gaps longer than 10 seconds are not counted.
    static func zoneSeconds(_ s: [Sample], _ bounds: [Int]) -> [Double] {
        var out = [Double](repeating: 0, count: 6)
        guard s.count > 1 else { return out }
        for i in 0..<(s.count - 1) {
            let dt = s[i + 1].t - s[i].t
            guard dt > 0, dt <= gapMs, s[i].hr > 0 else { continue }
            out[zone(s[i].hr, bounds)] += Double(dt) / 1000
        }
        return out
    }

    static let zoneWeights: [Double] = [0, 1, 2, 4, 7, 10]

    /// A 0 to 21 effort score from weighted minutes in each zone.
    static func strain(zoneSeconds z: [Double]) -> Double {
        var load = 0.0
        for (i, seconds) in z.enumerated() where i < zoneWeights.count { load += seconds / 60 * zoneWeights[i] }
        return min(21, 3.82 * log(1 + load / 6))
    }

    static func rmssd(_ values: [Int]) -> Double? {
        let clean = values.filter { $0 >= 300 && $0 <= 2000 }
        guard clean.count > 1 else { return nil }
        var sum = 0.0
        var n = 0
        for i in 1..<clean.count {
            let d = Double(clean[i] - clean[i - 1])
            guard abs(d) / Double(clean[i - 1]) <= 0.2 else { continue }
            sum += d * d
            n += 1
        }
        return n < 30 ? nil : (sum / Double(n)).squareRoot()
    }

    /// Median HRV across five-minute windows that have enough beat timing.
    static func hrv(_ s: [Sample]) -> Double? {
        var windows: [Int64: [Int]] = [:]
        for x in s where !x.rr.isEmpty { windows[x.t / 300_000, default: []] += x.rr }
        let values = windows.values.compactMap { rmssd($0) }.sorted()
        return values.isEmpty ? nil : values[values.count / 2]
    }

    /// Lowest five-minute average heart rate, ignoring sparse windows and single spikes.
    static func restingHR(_ s: [Sample]) -> Int? {
        var windows: [Int64: (sum: Int, n: Int)] = [:]
        for x in s where x.hr > 0 {
            let v = windows[x.t / 300_000] ?? (0, 0)
            windows[x.t / 300_000] = (v.sum + x.hr, v.n + 1)
        }
        let means = windows.values.filter { $0.n >= 150 }.map { Double($0.sum) / Double($0.n) }
        return means.min().map { Int($0.rounded()) }
    }

    static func average(_ s: [Sample]) -> Int? {
        let v = s.map(\.hr).filter { $0 > 0 }
        return v.isEmpty ? nil : Int((Double(v.reduce(0, +)) / Double(v.count)).rounded())
    }

    static func maxHR(_ s: [Sample]) -> Int? { s.map(\.hr).filter { $0 > 0 }.max() }

    /// Stretches where the per-minute average stayed in zone 1 or higher for at least
    /// `minMinutes`, allowing short dips.
    static func detectActivities(_ s: [Sample], threshold: Int, minMinutes: Int = 10, maxGap: Int = 2) -> [Span] {
        var minutes: [Int64: (sum: Int, n: Int)] = [:]
        for x in s where x.hr > 0 {
            let m = x.t / 60_000
            let v = minutes[m] ?? (0, 0)
            minutes[m] = (v.sum + x.hr, v.n + 1)
        }
        let active = minutes.filter { $0.value.n >= 20 && $0.value.sum / $0.value.n >= threshold }.keys.sorted()
        var out: [Span] = []
        var first: Int64?
        var last: Int64 = 0
        var count = 0
        for m in active {
            if first != nil, m - last <= Int64(maxGap + 1) {
                last = m
                count += 1
            } else {
                if let f = first, count >= minMinutes { out.append(Span(start: f * 60_000, end: (last + 1) * 60_000)) }
                first = m
                last = m
                count = 1
            }
        }
        if let f = first, count >= minMinutes { out.append(Span(start: f * 60_000, end: (last + 1) * 60_000)) }
        return out
    }

    /// Mifflin-St Jeor resting burn, per minute.
    static func bmrPerMinute(_ b: Body) -> Double {
        (10 * b.kg + 6.25 * b.cm - 5 * b.age + (b.female ? -161 : 5)) / 1440
    }

    /// Keytel exercise burn, kilocalories per minute.
    static func activePerMinute(_ hr: Int, _ b: Body) -> Double {
        let h = Double(hr)
        let kj = b.female
            ? -20.4022 + 0.4472 * h - 0.1263 * b.kg + 0.074 * b.age
            : -55.0969 + 0.6309 * h + 0.1988 * b.kg + 0.2017 * b.age
        return kj / 4.184
    }

    /// Resting burn for the whole period, plus the extra burned during readings in zone 1 or higher.
    static func calories(_ s: [Sample], body: Body, bounds: [Int], elapsedMinutes: Double) -> Double {
        let bmr = bmrPerMinute(body)
        var extra = 0.0
        if s.count > 1 {
            for i in 0..<(s.count - 1) {
                let dt = s[i + 1].t - s[i].t
                guard dt > 0, dt <= gapMs, zone(s[i].hr, bounds) >= 1 else { continue }
                extra += max(0, activePerMinute(s[i].hr, body) - bmr) * Double(dt) / 60_000
            }
        }
        return bmr * elapsedMinutes + extra
    }
}
