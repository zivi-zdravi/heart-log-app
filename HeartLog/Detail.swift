import Foundation

/// Words and small calculations for the Today card and the detail pages
/// (HRV, resting heart rate, calories, steps). Kept free of UI so it can be tested.
enum DetailMath {
    // MARK: Today card

    static func recoveryHeadline(_ recovery: Double?) -> String {
        guard let r = recovery else { return "No recovery yet" }
        switch SleepMath.level(r) {
        case .high: return "Well recovered"
        case .mid: return "Moderately recovered"
        case .low: return "Low recovery"
        }
    }

    /// One or two short sentences saying why recovery is where it is.
    static func recoveryReason(recovery: Double?, hrv: Double?, usualHRV: Double?, rhr: Int?, usualRHR: Double?) -> String {
        guard let r = recovery else { return "Shows after a night with the band on." }
        let h = compareHRV(hrv, usualHRV)
        let rr = compareRHR(rhr, usualRHR)
        var first: String
        switch (h, rr) {
        case (0, 0): first = "HRV and resting heart rate both in your usual range."
        case (1, 0), (1, -1): first = "HRV is above your usual."
        case (-1, 0), (-1, 1): first = "HRV is below your usual."
        case (0, 1): first = "Resting heart rate is higher than usual."
        case (0, -1): first = "Resting heart rate is lower than usual."
        case (1, 1): first = "HRV is up, but resting heart rate is higher than usual."
        case (-1, -1): first = "HRV is below your usual, resting heart rate is low."
        default: first = "Not enough nights yet to compare with your usual."
        }
        let advice: String
        switch SleepMath.level(r) {
        case .high: advice = "Room for a harder day."
        case .mid: advice = "A normal day is fine."
        case .low: advice = "Keep today light."
        }
        return first + " " + advice
    }

    /// 1 above usual, -1 below, 0 within, nil when there is nothing to compare.
    static func compareHRV(_ v: Double?, _ usual: Double?) -> Int? {
        guard let v, let u = usual, u > 0 else { return nil }
        return v > u * 1.1 ? 1 : v < u * 0.9 ? -1 : 0
    }

    static func compareRHR(_ v: Int?, _ usual: Double?) -> Int? {
        guard let v, let u = usual else { return nil }
        let d = Double(v) - u
        return d > 3 ? 1 : d < -3 ? -1 : 0
    }

    // MARK: HRV and resting heart rate pages

    /// The middle half of the values (25th to 75th percentile), from at least 5 nights.
    static func usualRange(_ values: [Double]) -> ClosedRange<Double>? {
        guard values.count >= 5 else { return nil }
        let s = values.sorted()
        func p(_ q: Double) -> Double {
            let x = Double(s.count - 1) * q
            let lo = Int(x.rounded(.down)), hi = Int(x.rounded(.up))
            return s[lo] + (s[hi] - s[lo]) * (x - Double(lo))
        }
        return p(0.25)...p(0.75)
    }

    /// Last 7 values against the ones before, as one word. `tolerance` is the change that counts.
    static func trendWord(_ values: [Double], tolerance: Double) -> String? {
        guard values.count >= 10 else { return nil }
        let recent = Array(values.suffix(7)), before = Array(values.dropLast(7))
        guard let a = TrendMath.mean(recent), let b = TrendMath.mean(before) else { return nil }
        return a - b > tolerance ? "rising" : b - a > tolerance ? "falling" : "steady"
    }

    struct Point: Equatable {
        let t: Int64
        let value: Double
    }

    /// HRV (RMSSD) for each five-minute window that has enough beat timing.
    static func hrvThroughNight(_ s: [Sample]) -> [Point] {
        var windows: [Int64: [Int]] = [:]
        for x in s where !x.rr.isEmpty { windows[x.t / 300_000, default: []] += x.rr }
        return windows.keys.sorted().compactMap { k in Metrics.rmssd(windows[k]!).map { Point(t: k * 300_000, value: $0) } }
    }

    /// Average heart rate for each five-minute window with at least half its readings.
    static func heartRateThroughNight(_ s: [Sample]) -> [Point] {
        var windows: [Int64: (sum: Int, n: Int)] = [:]
        for x in s where x.hr > 0 {
            let v = windows[x.t / 300_000] ?? (0, 0)
            windows[x.t / 300_000] = (v.sum + x.hr, v.n + 1)
        }
        return windows.keys.sorted().compactMap { k in
            let v = windows[k]!
            return v.n >= 150 ? Point(t: k * 300_000, value: Double(v.sum) / Double(v.n)) : nil
        }
    }

    struct Night {
        let value: Double
        let prevStrain: Double?
        let asleepMin: Double?
    }

    /// Plain sentences about what tends to move a value, from the person's own nights.
    /// Each comparison needs at least 4 nights on each side and a big enough difference.
    static func movers(_ nights: [Night], unit: String, minDiff: Double) -> [String] {
        var out: [String] = []
        func mean(_ v: [Double]) -> Double? { v.count >= 4 ? TrendMath.mean(v) : nil }
        func phrase(_ what: String, _ a: Double, _ b: Double) {
            let d = a - b
            guard abs(d) >= minDiff else { return }
            out.append("\(d > 0 ? "Higher" : "Lower") after \(what) (by about \(Int(abs(d).rounded())) \(unit)).")
        }
        let hard = nights.filter { ($0.prevStrain ?? 0) >= 14 }.map(\.value)
        let easy = nights.filter { $0.prevStrain != nil && $0.prevStrain! < 14 }.map(\.value)
        if let a = mean(hard), let b = mean(easy) { phrase("high-strain days", a, b) }
        let long = nights.filter { ($0.asleepMin ?? 0) >= 480 }.map(\.value)
        let short = nights.filter { $0.asleepMin != nil && $0.asleepMin! < 420 }.map(\.value)
        if let a = mean(long), let b = mean(short) { phrase("8+ hours of sleep", a, b) }
        return out
    }

    // MARK: Calories

    /// Burn for each hour of the day so far: resting for the time covered plus extra from heart rate.
    static func hourlyCalories(_ s: [Sample], dayStart: Int64, now: Int64, body: Metrics.Body, bounds: [Int]) -> [Double] {
        let hour: Int64 = 3_600_000
        let hours = Int(max(0, min(24, (now - dayStart + hour - 1) / hour)))
        var out: [Double] = []
        var i = 0
        let sorted = s.sorted { $0.t < $1.t }
        for h in 0..<hours {
            let a = dayStart + Int64(h) * hour, b = min(a + hour, now)
            var part: [Sample] = []
            while i < sorted.count, sorted[i].t < b {
                if sorted[i].t >= a { part.append(sorted[i]) }
                i += 1
            }
            out.append(Metrics.calories(part, body: body, bounds: bounds, elapsedMinutes: Double(b - a) / 60_000))
        }
        return out
    }

    /// Burn by the end of the day if the rest of it is spent resting.
    static func likelyByBedtime(burned: Double, now: Int64, dayEnd: Int64, body: Metrics.Body) -> Double {
        burned + Metrics.bmrPerMinute(body) * Double(max(0, dayEnd - now)) / 60_000
    }

    // MARK: Steps

    /// Rough minutes of walking for the steps left, at about 100 steps a minute, to the nearest 5.
    static func walkMinutes(_ steps: Int) -> Int {
        max(5, Int((Double(steps) / 100 / 5).rounded()) * 5)
    }

    static func stepsLine(steps: Int, goal: Int) -> String {
        let left = goal - steps
        if left <= 0 { return "Goal reached." }
        return "\(left.formatted()) to go. About a \(walkMinutes(left))-minute walk."
    }
}
