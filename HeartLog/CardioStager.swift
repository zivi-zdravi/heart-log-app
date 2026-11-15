import Foundation

/// Sleep stages from the band's per-second record: heart rate, beat timing and
/// wrist motion, scored in 30-second epochs against the sleeper's own night.
///
/// A Swift port of OpenStrap's cardioStager (analytics, onehz/sleep/
/// cardio_stager.dart and stager.dart, AGPL-3.0; see NOTICE), without the
/// rolling per-user profile blend (cold-start behaviour). Same features,
/// weights, cutoffs and clean-up passes, so its nights should read like
/// OpenStrap's.
enum CardioStager {
    enum Stage: Equatable { case wake, nrem, rem }

    struct Result: Equatable {
        var stages: [Stage]
        var deep: [Bool]
        var epochSec: Int
    }

    struct Input {
        var hr: [Double]            // per second, 0 = none
        var gravity: [[Double]]     // per second, x y z in g
        var tsMs: [Double]          // per second, real time
        var rrMs: [Double]          // beats, ascending by rrTsMs
        var rrTsMs: [Double]
        var runStarts: [Int]        // sample indices where a new run begins (multiples of 30)
    }

    static let epochSec = 30
    static let minHrCoverage = 0.5
    static let remCut = 0.5
    static let deepCut = 0.3
    static let wRem = (rk: 0.43, sdnn: 0.32, hrSd: 0.27, lfhf: 0.12)
    static let wDeep = (rk: 0.53, hrSd: 0.43, sdnn: 0.41, lfhf: 0.33)

    // MARK: Stats (same definitions as OpenStrap's util.dart)

    static func mean(_ x: [Double]) -> Double? { x.isEmpty ? nil : x.reduce(0, +) / Double(x.count) }

    /// Sample standard deviation (n - 1).
    static func stddev(_ x: [Double]) -> Double? {
        guard x.count >= 2, let m = mean(x) else { return nil }
        var s = 0.0
        for v in x { s += (v - m) * (v - m) }
        return (s / Double(x.count - 1)).squareRoot()
    }

    static func percentileSorted(_ s: [Double], _ p: Double) -> Double? {
        guard !s.isEmpty else { return nil }
        if s.count == 1 { return s[0] }
        let rank = p / 100 * Double(s.count - 1)
        let lo = Int(rank.rounded(.down)), hi = Int(rank.rounded(.up))
        if lo == hi { return s[lo] }
        return s[lo] + (s[hi] - s[lo]) * (rank - Double(lo))
    }

    static func median(_ x: [Double]) -> Double? { percentileSorted(x.sorted(), 50) }

    /// Scaled median absolute deviation.
    static func mad(_ x: [Double]) -> Double? {
        guard let m = median(x) else { return nil }
        return median(x.map { abs($0 - m) }).map { $0 * 1.4826 }
    }

    struct RobustScale {
        var med: Double, scale: Double
        static func of(_ x: [Double]) -> RobustScale? {
            guard x.count >= 2, let m = median(x), let s = mad(x), s != 0 else { return nil }
            return RobustScale(med: m, scale: s)
        }
        func z(_ v: Double) -> Double { (v - med) / scale }
    }

    // MARK: Staging

    static func stage(_ input: Input) -> Result? {
        let n = min(input.hr.count, input.gravity.count, input.tsMs.count)
        let perEpoch = epochSec // 1 Hz
        let nEpoch = n / perEpoch
        guard nEpoch >= 3 else { return nil }
        // Same coverage floor the decision layer applies, checked before the costly features.
        var withHR = 0
        for e in 0..<nEpoch where (e * perEpoch..<min(e * perEpoch + perEpoch, n)).contains(where: { input.hr[$0] > 0 }) { withHR += 1 }
        guard Double(withHR) / Double(nEpoch) >= minHrCoverage else { return nil }
        let segStarts = input.runStarts.map { $0 / perEpoch }.filter { $0 > 0 && $0 < nEpoch }
        let seg = segments(segStarts, nEpoch)

        // Motion: positive excess of |g| over a local 5-minute median.
        let mag = (0..<n).map { i -> Double in
            let g = input.gravity[i]
            return (g[0] * g[0] + g[1] * g[1] + g[2] * g[2]).squareRoot()
        }
        let gHalf = 300 / 2
        var motion = [Double](repeating: 0, count: nEpoch)
        var hr = [Double](repeating: .nan, count: nEpoch)
        var hrSd = [Double](repeating: 0, count: nEpoch)
        var rmssd = [Double](repeating: .nan, count: nEpoch)
        var sdnn = [Double](repeating: .nan, count: nEpoch)
        var lfhf = [Double](repeating: .nan, count: nEpoch)
        var rk = [Double](repeating: .nan, count: nEpoch)

        for e in 0..<nEpoch {
            let s = e * perEpoch, t = min(s + perEpoch, n)
            let segLo = seg.lo[e] * perEpoch
            let segHi = seg.hi[e] == nEpoch ? n : seg.hi[e] * perEpoch
            let lo = max(segLo, s - gHalf), hi = min(segHi, s + perEpoch + gHalf)
            let gRef = median(Array(mag[lo..<hi])) ?? 1
            var ms = 0.0
            for i in s..<t { ms += max(0, mag[i] - gRef) }
            motion[e] = ms / Double(t - s)
            let hv = (s..<t).map { input.hr[$0] }.filter { $0 > 0 }
            if let m = mean(hv) { hr[e] = m }
            if hv.count >= 2 { hrSd[e] = stddev(hv) ?? 0 }
            let centre = input.tsMs[(s + t) / 2]
            let wide = cleanBeats(input, centre: centre, halfMs: 150_000)
            rmssd[e] = windowRmssd(wide)
            if wide.beats.count >= 5 { sdnn[e] = stddev(wide.beats) ?? .nan }
            let r = remFeatures(cleanBeats(input, centre: centre, halfMs: 90_000))
            if let v = r.lfhf { lfhf[e] = v }
            if let v = r.rk { rk[e] = v }
        }
        return classify(motion: motion, hr: hr, hrSd: hrSd, rmssd: rmssd, lfhf: lfhf, rk: rk, sdnn: sdnn, segmentStarts: segStarts)
    }

    static func segments(_ starts: [Int], _ nEpoch: Int) -> (lo: [Int], hi: [Int]) {
        let bounds = Array(Set([0, nEpoch] + starts.filter { $0 > 0 && $0 < nEpoch })).sorted()
        var lo = [Int](repeating: 0, count: nEpoch), hi = [Int](repeating: nEpoch, count: nEpoch)
        for b in 0..<(bounds.count - 1) {
            for e in bounds[b]..<bounds[b + 1] { lo[e] = bounds[b]; hi[e] = bounds[b + 1] }
        }
        return (lo, hi)
    }

    struct Beats { var beats: [Double]; var tsSec: [Double]; var seam: [Bool] }

    /// Clean beats within ±halfMs of the centre: 300-2000 ms, no jump over 200 ms.
    /// `seam[k]` marks a beat that doesn't directly follow the previous one.
    static func cleanBeats(_ input: Input, centre: Double, halfMs: Double) -> Beats {
        var out = Beats(beats: [], tsSec: [], seam: [])
        let ts = input.rrTsMs, rr = input.rrMs
        guard !rr.isEmpty, ts.count == rr.count else { return out }
        let lo = centre - halfMs, hi = centre + halfMs
        var a = 0, b = ts.count
        while a < b { let m = (a + b) / 2; if ts[m] < lo { a = m + 1 } else { b = m } }
        var prev: Double?
        var broken = true
        var i = a
        while i < rr.count {
            let t = ts[i]
            if t > hi { break }
            let v = rr[i]
            if i > a && t - ts[i - 1] > v + 1000 { broken = true }
            if v < 300 || v > 2000 { prev = nil; broken = true; i += 1; continue }
            if let p = prev, abs(v - p) > 200 { prev = v; broken = true; i += 1; continue }
            out.beats.append(v)
            out.seam.append(broken)
            broken = false
            out.tsSec.append((t - lo) / 1000)
            prev = v
            i += 1
        }
        return out
    }

    static func windowRmssd(_ w: Beats) -> Double {
        guard w.beats.count >= 5 else { return .nan }
        var ss = 0.0, pairs = 0
        for i in 1..<w.beats.count where !w.seam[i] {
            let d = w.beats[i] - w.beats[i - 1]
            ss += d * d
            pairs += 1
        }
        return pairs >= 4 ? (ss / Double(pairs)).squareRoot() : .nan
    }

    static func remFeatures(_ w: Beats) -> (lfhf: Double?, rk: Double?) {
        guard w.beats.count >= 16 else { return (nil, nil) }
        var sum = 0.0, cnt = 0
        var prev: Double?
        for k in 0..<w.beats.count {
            let ihr = 60000 / w.beats[k]
            if let p = prev, !w.seam[k] { sum += abs(ihr - p); cnt += 1 }
            prev = ihr
        }
        let rk: Double? = cnt >= 15 ? sum / Double(cnt) : nil
        var lfhf: Double?
        let span = w.tsSec.last! - w.tsSec.first!
        if span > 0 {
            let lo = min(max(1 / span, 0.0005), 0.04)
            let grid = (0..<240).map { lo + (0.4 - lo) / 239 * Double($0) }
            // Same power as a plain Lomb-Scargle (up to a constant that cancels
            // in the ratio), computed without a trig call per beat per frequency.
            let p = BreathingMath.periodogram(w.tsSec, w.beats, lo: lo, hi: 0.4, count: 240)
            if p.count == grid.count {
                let lf = bandPower(grid, p, 0.04, 0.15), hf = bandPower(grid, p, 0.15, 0.40)
                if hf > 0 { lfhf = lf / hf }
            }
        }
        return (lfhf, rk)
    }

    /// Lomb-Scargle power at each frequency (unscaled; only ratios are used).
    static func lombScargle(_ t: [Double], _ y: [Double], _ freqs: [Double]) -> [Double]? {
        let n = t.count
        guard n >= 4, y.count == n else { return nil }
        let m = y.reduce(0, +) / Double(n)
        let yc = y.map { $0 - m }
        guard yc.reduce(0, { $0 + $1 * $1 }) > 0, (t.max() ?? 0) - (t.min() ?? 0) > 0 else { return nil }
        return freqs.map { f in
            let w = 2 * Double.pi * f
            guard w != 0 else { return 0 }
            var s2 = 0.0, c2 = 0.0
            for ti in t { s2 += sin(2 * w * ti); c2 += cos(2 * w * ti) }
            let tau = atan2(s2, c2) / (2 * w)
            var cn = 0.0, cd = 0.0, sn = 0.0, sd = 0.0
            for i in 0..<n {
                let a = w * (t[i] - tau)
                let c = cos(a), s = sin(a)
                cn += yc[i] * c; cd += c * c; sn += yc[i] * s; sd += s * s
            }
            return 0.5 * ((cd == 0 ? 0 : cn * cn / cd) + (sd == 0 ? 0 : sn * sn / sd))
        }
    }

    static func bandPower(_ f: [Double], _ p: [Double], _ lo: Double, _ hi: Double) -> Double {
        var out = 0.0
        for i in f.indices where f[i] >= lo && f[i] < hi {
            let df = i > 0 ? f[i] - f[i - 1] : (f.count > 1 ? f[1] - f[0] : 0)
            out += p[i] * df
        }
        return out
    }

    // MARK: Decision layer

    static func classify(motion: [Double], hr: [Double], hrSd: [Double], rmssd: [Double], lfhf: [Double], rk: [Double],
                         sdnn: [Double], segmentStarts: [Int] = []) -> Result? {
        let nEpoch = [motion.count, hr.count, hrSd.count, rmssd.count, lfhf.count, rk.count, sdnn.count].min() ?? 0
        guard nEpoch >= 3 else { return nil }
        let seg = segments(segmentStarts, nEpoch)

        let motMed = median(motion) ?? 0
        let motMadRaw = mad(motion) ?? 0
        let motUsable = motMadRaw > 0 && motMadRaw.isFinite
        let motMad = motUsable ? motMadRaw : 0
        let stillCut = motMed + 1.5 * motMad
        let bigMoveCut = motMed + 5 * motMad
        func still(_ e: Int) -> Bool { !motUsable || motion[e] <= stillCut }
        func bigMove(_ e: Int) -> Bool { motUsable && motion[e] > bigMoveCut }

        let sleepHr = (0..<nEpoch).filter { still($0) && !hr[$0].isNaN }.map { hr[$0] }
        let hrAll = hr.filter { !$0.isNaN }
        guard Double(hrAll.count) / Double(nEpoch) >= minHrCoverage else { return nil }
        let hrMedGlobal = median(sleepHr) ?? mean(hrAll)!

        // Local HR baselines over a 90-minute half window.
        let half = 180
        var hrMedLocal = [Double](repeating: hrMedGlobal, count: nEpoch)
        var hrArousal = [Double](repeating: hrMedGlobal + 6, count: nEpoch)
        var hrP25 = [Double](repeating: hrMedGlobal, count: nEpoch)
        for e in 0..<nEpoch {
            let lo = max(0, e - half), hi = min(nEpoch, e + half + 1)
            var win: [Double] = []
            for k in lo..<hi where still(k) && !hr[k].isNaN { win.append(hr[k]) }
            let sd = stddev(win)
            win.sort()
            if let m = percentileSorted(win, 50) {
                hrMedLocal[e] = m
                hrArousal[e] = m + max(6, sd ?? 6)
                hrP25[e] = percentileSorted(win, 25) ?? m
            }
        }

        func stillValues(_ a: [Double]) -> [Double] { (0..<nEpoch).filter { still($0) && !a[$0].isNaN }.map { a[$0] } }
        let sleepLfhf = stillValues(lfhf), sleepRk = stillValues(rk), sleepSdnn = stillValues(sdnn)
        let sleepHrSd = (0..<nEpoch).filter { still($0) && hrSd[$0] > 0 }.map { hrSd[$0] }
        let lfhfScale = RobustScale.of(sleepLfhf), rkScale = RobustScale.of(sleepRk)
        let sdnnScale = RobustScale.of(sleepSdnn), hrSdScale = RobustScale.of(sleepHrSd)

        var stages = [Stage](repeating: .wake, count: nEpoch)
        var deep = [Bool](repeating: false, count: nEpoch)
        for e in 0..<nEpoch {
            let hrUp = !hr[e].isNaN && hr[e] >= hrArousal[e]
            let bigPrev = e > seg.lo[e] && bigMove(e - 1)
            let bigMoveWake = bigMove(e) && ((!hr[e].isNaN && hr[e] >= hrMedLocal[e]) || bigPrev)
            if hrUp || bigMoveWake { stages[e] = .wake; continue }

            let rkZ = (sleepRk.count >= 4 && !rk[e].isNaN) ? rkScale?.z(rk[e]) : nil
            let sdnnZ = (sleepSdnn.count >= 4 && !sdnn[e].isNaN) ? sdnnScale?.z(sdnn[e]) : nil
            let lfhfZ = (sleepLfhf.count >= 4 && !lfhf[e].isNaN) ? lfhfScale?.z(lfhf[e]) : nil
            let hrSdZ = (sleepHrSd.count >= 4 && hrSd[e] > 0) ? hrSdScale?.z(hrSd[e]) : nil
            func score(_ terms: [(Double?, Double)]) -> Double? {
                var num = 0.0, den = 0.0
                for (z, w) in terms { guard let z, !z.isNaN else { continue }; num += z * w; den += abs(w) }
                return den == 0 ? nil : num / den
            }
            let remScore = score([(rkZ, wRem.rk), (sdnnZ, wRem.sdnn), (hrSdZ, wRem.hrSd), (lfhfZ, wRem.lfhf)])
            let deepScore = score([(rkZ, -wDeep.rk), (hrSdZ, -wDeep.hrSd), (sdnnZ, -wDeep.sdnn), (lfhfZ, -wDeep.lfhf)])
            let atonia = !bigMove(e)
            let hrTowardWake = !hr[e].isNaN && hr[e] >= hrP25[e]
            if let r = remScore, r > remCut, atonia, hrTowardWake {
                stages[e] = .rem
            } else {
                stages[e] = .nrem
                deep[e] = (deepScore ?? -.infinity) > deepCut
            }
        }

        var sm: [Stage] = []
        var lo = 0
        while lo < nEpoch {
            let hi = seg.hi[lo]
            var part = Array(stages[lo..<hi])
            modeFilter(&part)
            websterRescore(&part)
            consolidate(&part)
            sm += part
            lo = hi
        }
        for e in 0..<min(deep.count, sm.count) where deep[e] && sm[e] != .nrem { deep[e] = false }
        lo = 0
        while lo < nEpoch {
            let hi = seg.hi[lo]
            var part = Array(deep[lo..<hi])
            mergeShortDeep(&part, Array(sm[lo..<hi]))
            deep.replaceSubrange(lo..<hi, with: part)
            lo = hi
        }
        return Result(stages: sm, deep: deep, epochSec: epochSec)
    }

    static func modeFilter(_ s: inout [Stage]) {
        guard s.count >= 3 else { return }
        var out = s
        for i in 1..<(s.count - 1) where s[i - 1] == s[i + 1] && s[i] != s[i - 1] { out[i] = s[i - 1] }
        s = out
    }

    /// Bridges brief wake bouts that sit inside enough sleep (15 min bridges up
    /// to 4, 10 bridges 3, 4 bridges 1), measured on a snapshot so bridging
    /// can't cascade.
    static func websterRescore(_ sm: inout [Stage]) {
        let snap = sm
        let n = sm.count
        func isSleep(_ s: Stage) -> Bool { s != .wake }
        guard let onset = snap.firstIndex(where: isSleep), let last = snap.lastIndex(where: isSleep) else { return }
        func ep(_ m: Double) -> Double { m * 60 / Double(epochSec) }
        func runBefore(_ i: Int) -> Int { var c = 0, k = i - 1; while k >= onset && isSleep(snap[k]) { c += 1; k -= 1 }; return c }
        func runAfter(_ i: Int) -> Int { var c = 0, k = i + 1; while k <= last && isSleep(snap[k]) { c += 1; k += 1 }; return c }
        let rules = [(ep(15), ep(4)), (ep(10), ep(3)), (ep(4), ep(1))]
        var i = onset
        while i <= last && i < n {
            if isSleep(snap[i]) { i += 1; continue }
            var j = i
            while j <= last && !isSleep(snap[j]) { j += 1 }
            let len = Double(j - i)
            let ctx = Double(max(runBefore(i), runAfter(j - 1)))
            for r in rules where ctx >= r.0 && len <= r.1 {
                for k in i..<j { sm[k] = .nrem }
                break
            }
            i = j
        }
    }

    static func runs(_ s: [Stage]) -> [(Int, Int)] {
        var out: [(Int, Int)] = []
        var p = 0
        while p < s.count {
            var q = p
            while q < s.count && s[q] == s[p] { q += 1 }
            out.append((p, q))
            p = q
        }
        return out
    }

    /// Joins REM split by a short NREM gap, then folds sleep bouts under 5
    /// minutes into the longer neighbouring sleep bout. Wake is never touched.
    static func consolidate(_ sm: inout [Stage]) {
        let n = sm.count
        guard n > 0 else { return }
        let remGap = Int((5.0 * 60 / Double(epochSec)).rounded())
        let minBout = remGap
        let r1 = runs(sm)
        for ri in r1.indices {
            let (start, end) = r1[ri]
            guard sm[start] == .nrem else { continue }
            let gap = end - start
            if gap >= remGap { continue }
            let left = ri > 0 && sm[r1[ri - 1].0] == .rem ? r1[ri - 1].1 - r1[ri - 1].0 : 0
            let right = ri + 1 < r1.count && sm[r1[ri + 1].0] == .rem ? r1[ri + 1].1 - r1[ri + 1].0 : 0
            if left > 0 && right > 0 && left + right >= gap && left + right + gap >= remGap {
                for k in start..<end { sm[k] = .rem }
            }
        }
        var changed = true
        while changed {
            changed = false
            let r = runs(sm)
            for ri in r.indices {
                let (start, end) = r[ri]
                let stage = sm[start]
                guard stage != .wake, end - start < minBout else { continue }
                var left: Stage?, right: Stage?
                var ll = 0, rl = 0
                if ri > 0, sm[r[ri - 1].0] != .wake { left = sm[r[ri - 1].0]; ll = r[ri - 1].1 - r[ri - 1].0 }
                if ri + 1 < r.count, sm[r[ri + 1].0] != .wake { right = sm[r[ri + 1].0]; rl = r[ri + 1].1 - r[ri + 1].0 }
                let target: Stage?
                if let l = left, let rt = right { target = ll >= rl ? l : rt } else { target = left ?? right }
                guard let t = target, t != stage else { continue }
                for k in start..<end { sm[k] = t }
                changed = true
                break
            }
        }
    }

    static func mergeShortDeep(_ deep: inout [Bool], _ sm: [Stage]) {
        let minEp = Int((3.0 * 60 / Double(epochSec)).rounded())
        var i = 0
        while i < deep.count {
            guard deep[i], sm[i] == .nrem else { i += 1; continue }
            var j = i
            while j < deep.count && deep[j] && sm[j] == .nrem { j += 1 }
            if j - i < minEp { for k in i..<j { deep[k] = false } }
            i = j
        }
    }
}
