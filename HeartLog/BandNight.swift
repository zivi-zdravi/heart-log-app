import Foundation

/// Turns the band's per-second record into a night of sleep stages.
enum BandNight {
    /// Real-time seconds (Unix seconds), ascending and unique.
    typealias Seconds = [BandSecond]

    /// The night's in-bed span, from the band's own still/sleep state: the
    /// stretch with the most sleep, joining gaps of up to 30 minutes. Needs at
    /// least an hour the band called sleep. Unix seconds.
    static func window(_ secs: Seconds, maxGapMin: Int = 30, minSleepMin: Int = 60) -> (start: Int64, end: Int64)? {
        guard let first = secs.first?.t, let last = secs.last?.t else { return nil }
        let base = first - first % 60
        let count = Int((last - base) / 60) + 1
        var stillish = [Int](repeating: 0, count: count), sleep = [Int](repeating: 0, count: count), seen = [Int](repeating: 0, count: count)
        for s in secs {
            let m = Int((s.t - base) / 60)
            seen[m] += 1
            if s.sleepState == 1 || s.sleepState == 2 { stillish[m] += 1 }
            if s.sleepState == 2 { sleep[m] += 1 }
        }
        // A minute counts as in bed when most of its recorded seconds were still or asleep.
        let inBed = (0..<count).map { seen[$0] > 0 && stillish[$0] * 2 > seen[$0] }
        var best: (start: Int, end: Int, sleep: Int)?
        var m = 0
        while m < count {
            guard inBed[m] else { m += 1; continue }
            var end = m          // last in-bed minute of this block
            var sleepMin = 0
            var k = m
            var gap = 0
            while k < count {
                if inBed[k] {
                    end = k
                    gap = 0
                    if sleep[k] * 2 > seen[k] { sleepMin += 1 }
                } else {
                    gap += 1
                    if gap > maxGapMin { break }
                }
                k += 1
            }
            if sleepMin >= minSleepMin, sleepMin > (best?.sleep ?? 0) { best = (m, end, sleepMin) }
            m = end + 1
        }
        guard let b = best else { return nil }
        return (base + Int64(b.start) * 60, base + Int64(b.end + 1) * 60)
    }

    /// The stager's input for a span: one sample a second, short gaps (up to a
    /// minute) filled with "no reading", longer gaps starting a new run.
    static func input(_ secs: Seconds, from start: Int64, to end: Int64) -> CardioStager.Input {
        var input = CardioStager.Input(hr: [], gravity: [], tsMs: [], rrMs: [], rrTsMs: [], runStarts: [])
        var runStart = 0
        var prevT: Int64?
        var lastG: [Double] = [0, 0, 1]
        func trimRun() {
            // Each run must be whole 30-second epochs.
            let len = input.hr.count - runStart
            let keep = len - len % CardioStager.epochSec
            let cut = input.hr.count - (runStart + keep)
            guard cut > 0 else { return }
            let cutTs = input.tsMs[runStart + keep]
            input.hr.removeLast(cut); input.gravity.removeLast(cut); input.tsMs.removeLast(cut)
            while let t = input.rrTsMs.last, t >= cutTs { input.rrTsMs.removeLast(); input.rrMs.removeLast() }
        }
        for s in secs where s.t >= start && s.t < end {
            if let p = prevT {
                let gap = s.t - p
                if gap > 60 {
                    trimRun()
                    runStart = input.hr.count
                    if runStart > 0 { input.runStarts.append(runStart) }
                } else if gap > 1 {
                    for f in 1..<gap {
                        input.hr.append(0); input.gravity.append(lastG); input.tsMs.append(Double(p + f) * 1000)
                    }
                }
            }
            if let g = s.gravity { lastG = g.map(Double.init) }
            input.hr.append(Double(s.hr))
            input.gravity.append(lastG)
            input.tsMs.append(Double(s.t) * 1000)
            for v in s.rr { input.rrMs.append(Double(v)); input.rrTsMs.append(Double(s.t) * 1000) }
            prevT = s.t
        }
        trimRun()
        return input
    }

    /// Stage blocks for a night (Unix ms), or nil when it can't be staged.
    static func stages(_ secs: Seconds, fallback: (start: Int64, end: Int64)? = nil) -> [BandStage]? {
        guard let w = window(secs) ?? fallback else { return nil }
        let inp = input(secs, from: w.start, to: w.end)
        guard let r = CardioStager.stage(inp) else { return nil }
        var out: [BandStage] = []
        for e in r.stages.indices {
            let i = e * CardioStager.epochSec
            guard i < inp.tsMs.count else { break }
            let kind: BandStage.Kind
            switch r.stages[e] {
            case .wake: kind = .wake
            case .rem: kind = .rem
            case .nrem: kind = r.deep[e] ? .deep : .light
            }
            let s = Int64(inp.tsMs[i]), en = s + Int64(CardioStager.epochSec) * 1000
            if var last = out.last, last.kind == kind, last.end == s {
                last.end = en
                out[out.count - 1] = last
            } else {
                out.append(BandStage(start: s, end: en, kind: kind))
            }
        }
        return out.isEmpty ? nil : out
    }

    /// Steps in a span from the band's running step counter, which wraps at
    /// 65,536 and doesn't reset at midnight. Each rise between neighbouring
    /// records counts, as long as it's believable for the time between them
    /// (at most 5 steps a second, and gaps under 3 hours); anything else, like
    /// a counter reset, is skipped rather than guessed.
    static func steps(_ secs: Seconds) -> Int {
        var total = 0
        var prev: BandSecond?
        for s in secs {
            defer { prev = s }
            guard let p = prev else { continue }
            let gap = s.t - p.t
            guard gap > 0, gap <= 3 * 3600 else { continue }
            let delta = (s.steps - p.steps + 65_536) % 65_536
            if delta <= max(10, 5 * Int(gap)) { total += delta }
        }
        return total
    }

    /// Ascending, one record per second (the later copy wins).
    static func tidy(_ secs: [BandSecond]) -> Seconds {
        var byT: [Int64: BandSecond] = [:]
        for s in secs { byT[s.t] = s }
        return byT.keys.sorted().map { byT[$0]! }
    }
}
