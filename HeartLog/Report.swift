import Foundation

enum Report {
    private static let gapMs: Int64 = 10_000

    private struct Sample { let t: Int64; let hr: Int; let rr: [Int] }

    private static func rmssd(_ values: [Int]) -> Double? {
        let clean = values.filter { $0 >= 300 && $0 <= 2000 }
        guard clean.count > 1 else { return nil }
        var sum = 0.0, n = 0
        for i in 1..<clean.count where abs(Double(clean[i] - clean[i - 1])) / Double(clean[i - 1]) <= 0.2 {
            let d = Double(clean[i] - clean[i - 1])
            sum += d * d
            n += 1
        }
        return n < 30 ? nil : (sum / Double(n)).squareRoot()
    }

    private static func dur(_ ms: Int64) -> String {
        let m = Int(ms / 60000)
        return String(format: "%d:%02d", m / 60, m % 60)
    }

    static func title(_ id: String) -> String {
        guard let v = Double(id.dropFirst()) else { return id }
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: Date(timeIntervalSince1970: v / 1000))
    }

    static func build(_ id: String) -> String {
        let store = Store.shared
        var samples: [Sample] = []
        let raw = (try? String(contentsOf: store.samplesURL(id), encoding: .utf8)) ?? ""
        for line in raw.split(separator: "\n") {
            let p = line.split(separator: ",", omittingEmptySubsequences: false)
            guard p.count >= 5, let t = Int64(p[0]), let hr = Int(p[1]) else { continue }
            samples.append(Sample(t: t, hr: hr, rr: p[4].split(separator: ";").compactMap { Int($0) }))
        }
        samples.sort { $0.t < $1.t }

        var events: [(t: Int64, type: String, detail: String)] = []
        let rawEvents = (try? String(contentsOf: store.eventsURL(id), encoding: .utf8)) ?? ""
        for line in rawEvents.split(separator: "\n") {
            let p = line.split(separator: ",", maxSplits: 2, omittingEmptySubsequences: false).map { "\($0)" }
            if p.count == 3, let t = Int64(p[0]) { events.append((t, p[1], p[2])) }
        }
        func count(_ type: String) -> Int { events.filter { $0.type == type }.count }

        let time = DateFormatter()
        time.timeStyle = .short
        func clock(_ ms: Int64) -> String { time.string(from: Date(timeIntervalSince1970: Double(ms) / 1000)) }

        let start = events.first?.t ?? samples.first?.t ?? 0
        let end = max(samples.last?.t ?? start, events.last?.t ?? start)
        var covered: Int64 = 0, prev = start
        var gaps: [(from: Int64, to: Int64)] = []
        for s in samples {
            if s.t - prev >= gapMs { gaps.append((prev, s.t)) } else { covered += s.t - prev }
            prev = s.t
        }
        let length = max(end - start, 1)
        let pct = min(100, 100 * Double(covered) / Double(length))
        let hrs = samples.map(\.hr).filter { $0 > 0 }
        let withRR = samples.filter { !$0.rr.isEmpty }.count

        var windows: [Int64: [Int]] = [:]
        var perHour: [Int64: Int] = [:]
        let cal = Calendar.current
        for s in samples {
            perHour[s.t / 3_600_000, default: 0] += 1
            let hour = cal.component(.hour, from: Date(timeIntervalSince1970: Double(s.t) / 1000))
            if hour >= 2 && hour < 6 { windows[s.t / 300_000, default: []] += s.rr }
        }
        let hrv = windows.values.compactMap(rmssd).sorted()

        let verdict = pct >= 90 ? "GOOD" : pct >= 60 ? "PARTIAL" : "POOR"
        let header = events.first(where: { $0.type == "start" })?.detail ?? ""
        let bats = events.filter { $0.type == "battery" }.map(\.detail)
        var out: [String] = [
            "HEART LOG REPORT",
            "Profile and band: \(header)",
            "Started: \(title(id))   Ended: \(clock(end))",
            "Length: \(dur(length))   Captured: \(dur(covered)) (\(String(format: "%.1f", pct))%)",
            "Result: \(verdict)",
            "",
            "Readings: \(samples.count)   With beat timing: \(samples.isEmpty ? 0 : 100 * withRR / samples.count)%",
            "Heart rate low/avg/high: \(hrs.min() ?? 0) / \(hrs.isEmpty ? 0 : hrs.reduce(0, +) / hrs.count) / \(hrs.max() ?? 0)",
            "HRV, 2 to 6 a.m.: \(hrv.isEmpty ? "not enough data" : String(format: "%.1f ms (%d windows)", hrv[hrv.count / 2], hrv.count))",
            "Battery: \(bats.isEmpty ? "not available" : "\(bats[0])% to \(bats[bats.count - 1])% (\(bats.count) checks)")",
            "Went to background: \(count("background"))   Locked: \(count("locked"))",
            "Disconnects: \(count("disconnected"))   Failed connects: \(count("connect_failed"))",
            "App relaunches in background: \(events.filter { $0.type == "launch" && $0.detail == "background" }.count)   Bluetooth restores: \(count("restored"))",
            "File write errors this run: \(store.writeErrors)",
            "Gaps over 10 sec: \(gaps.count), total \(dur(gaps.reduce(0) { $0 + $1.to - $1.from }))"
        ]
        let biggest = gaps.sorted { ($0.to - $0.from) > ($1.to - $1.from) }.prefix(8).sorted { $0.from < $1.from }
        if !biggest.isEmpty {
            out.append("Largest gaps:")
            biggest.forEach { out.append("  \(clock($0.from)) to \(clock($0.to)) (\(($0.to - $0.from) / 1000) sec)") }
        }
        out.append("Readings per hour:")
        perHour.keys.sorted().forEach { out.append("  \(clock($0 * 3_600_000)): \(perHour[$0] ?? 0)") }
        return out.joined(separator: "\n")
    }
}
