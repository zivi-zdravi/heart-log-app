import Foundation

/// Phase 1 of the band history download: Zdravlje LISTENS to history the band
/// sends to another app (OpenStrap) on the shared connection. It never asks
/// for history and never answers the band's batch markers, so the band's
/// memory is untouched and OpenStrap still gets everything.
///
/// Records are saved per local day in band-YYYY-MM-DD.bin (36 bytes a
/// second, real time), kept on this phone only (not in backups), pruned
/// after 21 days. After each transfer, nights that got new data are staged.
final class BandCapture: ObservableObject {
    static let shared = BandCapture()

    @Published private(set) var lastData: Date?
    @Published private(set) var lastStaged: Date?
    @Published private(set) var secondsToday = 0

    private let queue = DispatchQueue(label: "band.capture")
    private var pending: [BandSecond] = []
    private var flushWork: DispatchWorkItem?
    private static let keepDays = 21

    private var dir: URL {
        let d = Store.shared.dir.appendingPathComponent("band", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private func url(_ day: String) -> URL { dir.appendingPathComponent("band-\(day).bin") }

    private static let dayFormat: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private func dayKey(_ unix: Int64) -> String { Self.dayFormat.string(from: Date(timeIntervalSince1970: Double(unix))) }

    // MARK: From the band link

    /// A v18 second in the band's clock; `offset` is band minus phone, in seconds.
    func add(_ s: BandSecond, offset: Int) {
        var r = s
        r.t -= Int64(offset)
        queue.async {
            self.pending.append(r)
            if self.pending.count >= 600 { self.flush(stage: false) }
            self.scheduleFlush()
        }
        DispatchQueue.main.async { self.lastData = Date() }
    }

    /// Writes everything received so far to disk, then calls back on the main
    /// queue. Used before confirming a batch, which lets the band erase it.
    func saveNow(stage: Bool = false, _ done: @escaping () -> Void) {
        queue.async {
            self.flushWork?.cancel()
            self.flush(stage: stage)
            DispatchQueue.main.async(execute: done)
        }
    }

    /// End of a batch or of the whole transfer: save and stage now.
    func marker(_ m: BandHistoryMarker) {
        guard m != .start else { return }
        queue.async {
            self.flushWork?.cancel()
            self.flush(stage: m == .complete)
        }
    }

    /// If the transfer just stops, save and stage after a quiet minute.
    private func scheduleFlush() {
        flushWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.flush(stage: true) }
        flushWork = w
        queue.asyncAfter(deadline: .now() + 60, execute: w)
    }

    // MARK: Storage

    private var touched: Set<String> = []

    private func flush(stage: Bool) {
        if !pending.isEmpty {
            let byDay = Dictionary(grouping: pending) { dayKey($0.t) }
            pending.removeAll()
            for (day, secs) in byDay {
                let bytes = secs.flatMap { $0.encoded() }
                let u = url(day)
                if let h = try? FileHandle(forWritingTo: u) {
                    h.seekToEndOfFile()
                    h.write(Data(bytes))
                    try? h.close()
                } else {
                    try? Data(bytes).write(to: u)
                }
                touched.insert(day)
            }
            prune()
            // Seconds for a day that's already finished (a walk without the
            // phone, synced after midnight) change its strain and calories.
            let today = dayKey(Int64(Date().timeIntervalSince1970))
            if let earliest = byDay.keys.filter({ $0 < today }).min() { DayEngine.shared.invalidate(from: earliest) }
        }
        if stage, !touched.isEmpty {
            let days = touched
            touched.removeAll()
            stageNights(touching: days)
        }
    }

    func load(day: String) -> [BandSecond] {
        guard let d = try? Data(contentsOf: url(day)) else { return [] }
        let b = [UInt8](d)
        var out: [BandSecond] = []
        out.reserveCapacity(b.count / BandSecond.size)
        var i = 0
        while i + BandSecond.size <= b.count {
            if let s = BandSecond.decodeStored(b[i..<(i + BandSecond.size)]) { out.append(s) }
            i += BandSecond.size
        }
        return out
    }

    private func prune() {
        let cutoff = dayKey(Int64(Date().timeIntervalSince1970) - Int64(Self.keepDays) * 86_400)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        for f in files where f.hasPrefix("band-") && f.hasSuffix(".bin") {
            let day = String(f.dropFirst(5).dropLast(4))
            if day < cutoff { try? FileManager.default.removeItem(at: dir.appendingPathComponent(f)) }
        }
    }

    // MARK: Staging

    /// Seconds from 6 PM the evening before a wake day to 2 PM on it.
    func nightSeconds(wakeDay: Date) -> [BandSecond] {
        let cal = Calendar.current
        let day = cal.startOfDay(for: wakeDay)
        guard let prev = cal.date(byAdding: .day, value: -1, to: day) else { return [] }
        let from = Int64(prev.timeIntervalSince1970) + 18 * 3600
        let to = Int64(day.timeIntervalSince1970) + 14 * 3600
        let raw = load(day: dayKey(Int64(prev.timeIntervalSince1970) + 43_200)) + load(day: dayKey(Int64(day.timeIntervalSince1970) + 43_200))
        return BandNight.tidy(raw.filter { $0.t >= from && $0.t < to })
    }

    private func stageNights(touching days: Set<String>) {
        let cal = Calendar.current
        var wakeDays: Set<Date> = []
        for key in days {
            guard let d = Self.dayFormat.date(from: key) else { continue }
            let start = cal.startOfDay(for: d)
            wakeDays.insert(start)
            if let next = cal.date(byAdding: .day, value: 1, to: start) { wakeDays.insert(next) }
        }
        var changed = false
        for wake in wakeDays.sorted() {
            let secs = nightSeconds(wakeDay: wake)
            guard secs.count >= 3600, let stages = BandNight.stages(secs) else { continue }
            let key = DayEngine.shared.key(wake)
            BandHistoryStore.shared.setOwn(BandDay(day: key, source: "zdravlje", stages: stages))
            changed = true
        }
        let todayCount = load(day: dayKey(Int64(Date().timeIntervalSince1970))).count
        DispatchQueue.main.async {
            self.secondsToday = todayCount
            if changed { self.lastStaged = Date() }
        }
        if changed { DayEngine.shared.invalidateAll() }
    }

    /// Band-counted steps for a local calendar day, and how many minutes of records it had.
    func steps(day: Date) -> (steps: Int, minutes: Int) {
        let cal = Calendar.current
        let start = Int64(cal.startOfDay(for: day).timeIntervalSince1970)
        let end = start + 86_400
        // The previous day's last record lets the first rise after midnight count.
        let raw = load(day: dayKey(start - 43_200)).filter { $0.t >= start - 600 } + load(day: dayKey(start + 43_200))
        let secs = BandNight.tidy(raw.filter { $0.t < end })
        let inDay = secs.filter { $0.t >= start }
        guard !inDay.isEmpty else { return (0, 0) }
        let lead = secs.last { $0.t < start }
        return (BandNight.steps((lead.map { [$0] } ?? []) + inDay), inDay.count / 60)
    }

    /// Bump when the night rules change, so saved nights get worked out again.
    static let nightRulesVersion = 2

    func restageIfRulesChanged() {
        let key = "nightRulesVersion"
        guard UserDefaults.standard.integer(forKey: key) != Self.nightRulesVersion else { return }
        UserDefaults.standard.set(Self.nightRulesVersion, forKey: key)
        restageRecent()
    }

    /// Re-stage the last few nights from saved data (Settings button, and after an update).
    func restageRecent(days: Int = 14) {
        queue.async {
            let cal = Calendar.current
            let today = cal.startOfDay(for: Date())
            var keys: Set<String> = []
            for i in 0..<days {
                if let d = cal.date(byAdding: .day, value: -i, to: today) { keys.insert(self.dayKey(Int64(d.timeIntervalSince1970) + 43_200)) }
            }
            self.stageNights(touching: keys)
        }
    }
}
