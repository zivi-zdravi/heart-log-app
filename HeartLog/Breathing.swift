import Foundation

/// Breathing rate during sleep, from beat timing. Breathing in speeds the heart
/// slightly and breathing out slows it (respiratory sinus arrhythmia), so the
/// beat intervals rise and fall at the breathing rate.
///
/// Ported from OpenStrap's analytics (rsaRespRate in respiration/resp_rate.dart,
/// AGPL-3.0; see NOTICE): the night is cut into 5-minute windows overlapping by
/// half, each window's strongest rhythm between 9 and 30 breaths a minute is
/// found with a Lomb-Scargle periodogram, and the night's rate is the median of
/// those. When the windows don't agree with each other, nothing is reported
/// rather than a guess.
enum BreathingMath {
    struct Beat: Equatable { var t: Double; var nn: Double }   // seconds, milliseconds

    struct Estimate: Equatable {
        var brpm: Double
        var usable: Int
        var windows: Int
    }

    static let loHz = 0.15
    static let hiHz = 0.40
    static let capHz = 0.5
    static let segmentSec = 300.0
    static let tolerance = 2.0
    static let minConsensus = 0.5
    static let maxArtifact = 0.30

    /// The highest rate a window with this beat interval can resolve.
    static func ceilingHz(_ beatSec: Double) -> Double {
        guard beatSec.isFinite, beatSec > 0 else { return capHz }
        return min(0.5 / beatSec, capHz)
    }

    /// Beats from recorded samples, with impossible intervals and sudden jumps
    /// (missed or extra beats) dropped. Returns the beats and the share dropped.
    static func beats(_ samples: [Sample]) -> (beats: [Beat], artifact: Double) {
        var out: [Beat] = []
        var total = 0
        var recent: [Double] = []
        // Beat times run on from the previous beat (the broadcast only says which
        // second a beat arrived in), and re-anchor to the sample's time after a
        // gap or drift.
        var cursor: Double?
        for s in samples where !s.rr.isEmpty {
            let at = Double(s.t) / 1000
            let sum = Double(s.rr.reduce(0, +)) / 1000
            var t: Double
            if let c = cursor, abs(c + sum - at) <= 2 { t = c } else { t = at - sum }
            for rr in s.rr {
                let nn = Double(rr)
                t += nn / 1000
                total += 1
                guard nn >= 300, nn <= 2000 else { continue }
                if recent.count >= 3 {
                    let m = recent.sorted()[recent.count / 2]
                    if abs(nn - m) > 0.2 * m { continue }
                }
                if let last = out.last, t <= last.t { continue }
                out.append(Beat(t: t, nn: nn))
                recent.append(nn)
                if recent.count > 5 { recent.removeFirst() }
            }
            cursor = t
        }
        return (out, total == 0 ? 1 : 1 - Double(out.count) / Double(total))
    }

    static func median(_ v: [Double]) -> Double? {
        guard !v.isEmpty else { return nil }
        let s = v.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    /// Lomb-Scargle power on an evenly spaced frequency grid, using angle
    /// addition so each step is multiplies rather than trig calls.
    static func periodogram(_ t: [Double], _ y: [Double], lo: Double, hi: Double, count: Int) -> [Double] {
        let n = t.count
        guard n > 2, count > 1 else { return [] }
        let mean = y.reduce(0, +) / Double(n)
        let yc = y.map { $0 - mean }
        let t0 = t[0]
        let tt = t.map { $0 - t0 }
        let step = (hi - lo) / Double(count - 1)
        var c = [Double](repeating: 0, count: n), s = c, dc = c, ds = c
        for i in 0..<n {
            let a = 2 * Double.pi * lo * tt[i], d = 2 * Double.pi * step * tt[i]
            c[i] = cos(a); s[i] = sin(a); dc[i] = cos(d); ds[i] = sin(d)
        }
        var power = [Double](repeating: 0, count: count)
        for k in 0..<count {
            var s2 = 0.0, c2 = 0.0
            for i in 0..<n {
                s2 += 2 * s[i] * c[i]
                c2 += c[i] * c[i] - s[i] * s[i]
            }
            // tau rotates every point so the sine and cosine terms are orthogonal.
            let half = atan2(s2, c2) / 2
            let ct = cos(half), st = sin(half)
            var yc1 = 0.0, ys1 = 0.0, cc = 0.0, ss = 0.0
            for i in 0..<n {
                let cr = c[i] * ct + s[i] * st
                let sr = s[i] * ct - c[i] * st
                yc1 += yc[i] * cr; ys1 += yc[i] * sr
                cc += cr * cr; ss += sr * sr
            }
            power[k] = 0.5 * ((cc > 0 ? yc1 * yc1 / cc : 0) + (ss > 0 ? ys1 * ys1 / ss : 0))
            for i in 0..<n {
                let nc = c[i] * dc[i] - s[i] * ds[i]
                s[i] = s[i] * dc[i] + c[i] * ds[i]
                c[i] = nc
            }
        }
        return power
    }

    /// The night's breathing rate, or nil when the beats can't support one.
    static func rate(_ beats: [Beat], artifact: Double) -> Estimate? {
        guard beats.count >= 20, artifact <= maxArtifact, let first = beats.first, let last = beats.last,
              let med = median(beats.map(\.nn)) else { return nil }
        let span = last.t - first.t
        guard span > 0, ceilingHz(med / 1000) >= hiHz else { return nil }
        var seg = segmentSec
        if span < 2 * seg { seg = span / 2 }
        guard seg >= 60 else { return nil }

        let times = beats.map(\.t)
        func lowerBound(_ v: Double) -> Int {
            var lo = 0, hi = times.count
            while lo < hi { let m = (lo + hi) / 2; if times[m] < v { lo = m + 1 } else { hi = m } }
            return lo
        }

        var peaks: [Double] = []
        var tried = 0
        var atFloor = 0
        var start = first.t
        while start + seg <= last.t + 1e-9 {
            defer { start += seg / 2 }
            tried += 1
            let a = lowerBound(start), b = lowerBound(start + seg)
            let window = Array(beats[a..<b])
            // At least 80% of the window covered by kept beats, and enough of them.
            guard window.reduce(0, { $0 + $1.nn }) / 1000 >= seg * 0.8, window.count >= 30,
                  let wm = median(window.map(\.nn)) else { continue }
            let top = ceilingHz(wm / 1000)
            guard top >= hiHz else { continue }
            let segSpan = window.last!.t - window.first!.t
            let count = max(64, Int(((top - loHz) * 4 * segSpan).rounded(.up)))
            let p = periodogram(window.map(\.t), window.map(\.nn), lo: loHz, hi: top, count: count)
            guard let k = p.indices.max(by: { p[$0] < p[$1] }), p[k] > 0 else { continue }
            let stepHz = (top - loHz) / Double(count - 1)
            let f = loHz + Double(k) * stepHz
            // A peak on the top edge means the true rate is beyond what this window can see.
            if f >= top - stepHz { continue }
            // On the bottom edge, the true rate may be below the band.
            if f <= loHz + min(2 / segSpan, 2 / segmentSec) { atFloor += 1; continue }
            peaks.append(f * 60)
        }
        guard peaks.count >= 3, let m = median(peaks) else { return nil }
        let within = peaks.filter { abs($0 - m) <= tolerance }.count
        guard Double(within) / Double(peaks.count + atFloor) >= minConsensus else { return nil }
        // The window closest to the median, so the number is one a window actually measured.
        let best = peaks.min { abs($0 - m) < abs($1 - m) } ?? m
        return Estimate(brpm: (best * 10).rounded() / 10, usable: peaks.count, windows: tried)
    }

    /// Breathing rate for a night's samples.
    static func night(_ samples: [Sample]) -> Estimate? {
        let b = beats(samples)
        return rate(b.beats, artifact: b.artifact)
    }
}
