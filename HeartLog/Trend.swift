import Foundation

/// One day's value on a trend chart.
struct TrendValue: Equatable {
    var date: Date
    var value: Double
    var app: Bool
}

/// A week's average and range, for the Year view.
struct TrendWeek: Equatable {
    var start: Date
    var mean: Double
    var low: Double
    var high: Double
    var app: Bool
}

enum TrendMath {
    static func mean(_ v: [Double]) -> Double? { v.isEmpty ? nil : v.reduce(0, +) / Double(v.count) }

    /// Groups days into calendar weeks.
    static func weekly(_ values: [TrendValue], calendar: Calendar) -> [TrendWeek] {
        var groups: [Date: [TrendValue]] = [:]
        for v in values {
            guard let start = calendar.dateInterval(of: .weekOfYear, for: v.date)?.start else { continue }
            groups[start, default: []].append(v)
        }
        return groups.keys.sorted().compactMap { k in
            let g = groups[k]!.map(\.value)
            guard let m = mean(g) else { return nil }
            return TrendWeek(start: k, mean: m, low: g.min()!, high: g.max()!, app: groups[k]!.contains(where: \.app))
        }
    }

    /// Average of each day and up to 6 days before it, among the days that have values.
    static func trailing(_ values: [TrendValue], days: Int = 7, calendar: Calendar) -> [TrendValue] {
        values.map { v in
            let from = calendar.date(byAdding: .day, value: -(days - 1), to: v.date) ?? v.date
            let window = values.filter { $0.date >= from && $0.date <= v.date }.map(\.value)
            return TrendValue(date: v.date, value: mean(window) ?? v.value, app: v.app)
        }
    }

    /// A y-axis range that fits the data with some room, at least `minSpan` wide.
    static func domain(_ values: [Double], minSpan: Double, floor: Double? = nil) -> ClosedRange<Double> {
        guard let lo = values.min(), let hi = values.max() else { return 0...max(1, minSpan) }
        var a = lo - (hi - lo) * 0.15
        var b = hi + (hi - lo) * 0.15
        if b - a < minSpan {
            let mid = (a + b) / 2
            a = mid - minSpan / 2
            b = mid + minSpan / 2
        }
        if let f = floor, a < f { b += f - a; a = f }
        return a...b
    }

    /// "up from", "down from" or "about the same as", with a tolerance.
    static func change(_ now: Double, _ before: Double, tolerance: Double) -> String {
        if abs(now - before) <= tolerance { return "about the same as" }
        return now > before ? "up from" : "down from"
    }
}
