import Foundation

/// Fills holes in the live heart rate stream with the band's own per-second
/// record. The live stream can drop (phone left at home, a stalled
/// connection, iOS pausing the app), but the band keeps recording and hands
/// those seconds over at the next history download.
///
/// Used for daytime numbers: strain, calories, activities and suggestions.
/// Sleep keeps using the live stream only, so its tuning stays as it was.
enum HRFill {
    /// A band second is used only when no live reading is this close to it.
    static let nearMs: Int64 = 5_000

    /// Live readings plus band seconds that fall where the live stream was
    /// silent, oldest first. `band` is in phone time (Unix seconds).
    static func merge(live: [Sample], band: [BandSecond]) -> [Sample] {
        guard !band.isEmpty else { return live }
        let times = live.map(\.t)   // live is sorted by time
        var added: [Sample] = []
        for b in band where b.hr > 0 {
            let t = b.t * 1000
            if !hasNear(times, t) { added.append(Sample(t: t, hr: b.hr, rr: b.rr)) }
        }
        guard !added.isEmpty else { return live }
        return (live + added).sorted { $0.t < $1.t }
    }

    private static func hasNear(_ times: [Int64], _ t: Int64) -> Bool {
        var lo = 0, hi = times.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if times[mid] < t { lo = mid + 1 } else { hi = mid }
        }
        if lo < times.count, times[lo] - t <= nearMs { return true }
        if lo > 0, t - times[lo - 1] <= nearMs { return true }
        return false
    }

    /// Stretches of at least `minMinutes` of steady walking or running. A
    /// minute counts when the band labelled at least 80% of it walk or run
    /// AND counted at least `minSteps` steps, or when it counted at least
    /// `strongSteps` steps on its own. A single slow minute (`maxGap`) doesn't
    /// break a stretch. Times in milliseconds.
    ///
    /// Tuned on a real hilly walk (Nov 24, 2026): moving around the house
    /// shows the walk label on and off with 20 to 45 steps a minute; the walk
    /// itself was labelled the whole minute at 40 to 100 steps.
    static func moves(_ band: [BandSecond], minMinutes: Int = 10, maxGap: Int = 1,
                      minSteps: Int = 30, strongSteps: Int = 80) -> [Metrics.Span] {
        guard band.count > 1 else { return [] }
        var seen: [Int64: Int] = [:]
        var moving: [Int64: Int] = [:]
        var steps: [Int64: Int] = [:]
        var prev: BandSecond?
        for s in band {
            let m = s.t / 60
            seen[m, default: 0] += 1
            if s.activity == 1 || s.activity == 2 { moving[m, default: 0] += 1 }
            if let p = prev, s.t - p.t > 0, s.t - p.t <= 60 {
                let delta = (s.steps - p.steps + 65_536) % 65_536
                if delta <= max(10, 5 * Int(s.t - p.t)) { steps[m, default: 0] += delta }
            }
            prev = s
        }
        let active = seen.keys.filter { m in
            let n = seen[m] ?? 0
            guard n >= 20 else { return false }
            let st = steps[m] ?? 0
            return (Double(moving[m] ?? 0) >= 0.8 * Double(n) && st >= minSteps) || st >= strongSteps
        }.sorted()
        var out: [Metrics.Span] = []
        var first: Int64?
        var last: Int64 = 0
        var count = 0
        for m in active {
            if first != nil, m - last <= Int64(maxGap + 1) {
                last = m
                count += 1
            } else {
                if let f = first, count >= minMinutes { out.append(Metrics.Span(start: f * 60_000, end: (last + 1) * 60_000)) }
                first = m
                last = m
                count = 1
            }
        }
        if let f = first, count >= minMinutes { out.append(Metrics.Span(start: f * 60_000, end: (last + 1) * 60_000)) }
        return out
    }

    /// Joins overlapping or touching stretches.
    static func union(_ spans: [Metrics.Span]) -> [Metrics.Span] {
        var out: [Metrics.Span] = []
        for s in spans.sorted(by: { $0.start < $1.start }) {
            if let l = out.last, s.start <= l.end {
                out[out.count - 1] = Metrics.Span(start: l.start, end: max(l.end, s.end))
            } else {
                out.append(s)
            }
        }
        return out
    }
}
