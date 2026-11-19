import Foundation

/// Band-measured days, saved in bandhistory.json and included in backups.
final class BandHistoryStore {
    static let shared = BandHistoryStore()
    static let fileName = "bandhistory.json"
    private let lock = NSLock()
    private var data: BandHistoryData

    private static var url: URL { Store.shared.dir.appendingPathComponent(fileName) }

    private init() {
        data = (try? JSONDecoder().decode(BandHistoryData.self, from: Data(contentsOf: Self.url))) ?? BandHistoryData()
    }

    /// Every day, Zdravlje's own stages winning over imported ones.
    var days: [String: BandDay] { lock.lock(); defer { lock.unlock() }; return data.combined }
    /// Only what came from OpenStrap imports.
    var imported: [String: BandDay] { lock.lock(); defer { lock.unlock() }; return data.days }
    /// Only nights Zdravlje staged itself.
    var own: [String: BandDay] { lock.lock(); defer { lock.unlock() }; return data.own ?? [:] }

    func setOwn(_ d: BandDay) {
        lock.lock()
        var o = data.own ?? [:]
        guard o[d.day] != d else { lock.unlock(); return }
        o[d.day] = d
        data.own = o
        JSONFile.write(data, to: Self.url)
        lock.unlock()
    }

    func day(_ key: String) -> BandDay? {
        lock.lock(); defer { lock.unlock() }
        if let o = data.own?[key] { return data.days[key].map { o.filling(from: $0) } ?? o }
        return data.days[key]
    }

    func reload() {
        let fresh = (try? JSONDecoder().decode(BandHistoryData.self, from: Data(contentsOf: Self.url))) ?? BandHistoryData()
        lock.lock()
        data = fresh
        lock.unlock()
        DayEngine.shared.invalidateAll()
    }

    @discardableResult
    func merge(_ incoming: BandHistoryData) -> Int {
        lock.lock()
        var (merged, changed) = OpenStrapImport.merge(incoming, into: data)
        // Keep this phone's own nights; a backup's own nights fill only gaps.
        var own = data.own ?? [:]
        for (k, v) in incoming.own ?? [:] where own[k] == nil { own[k] = v; changed += 1 }
        merged.own = own.isEmpty ? nil : own
        data = merged
        JSONFile.write(merged, to: Self.url)
        lock.unlock()
        if changed > 0 { DayEngine.shared.invalidateAll() }
        return changed
    }

    /// Merges bandhistory.json from a backup.
    @discardableResult
    func merge(json: Data) -> Int {
        guard let incoming = try? JSONDecoder().decode(BandHistoryData.self, from: json) else { return 0 }
        return merge(incoming)
    }
}

extension PhoneUse {
    /// Set by the recorder: true while the app is open on screen.
    static var appOnScreen = false

    /// Phone use logged by any recording between two times.
    static func read(from: Int64, to: Int64) -> [Span] {
        var events: [(Int64, String)] = []
        for id in Store.shared.sessions() {
            guard let started = Int64(id.dropFirst()), started <= to else { continue }
            let csv = (try? String(contentsOf: Store.shared.eventsURL(id), encoding: .utf8)) ?? ""
            events += parse(csv).filter { ($0.1 == "unlocked" || $0.1 == "locked") && $0.0 >= from - 3_600_000 && $0.0 <= to }
        }
        // With the app on screen the phone is unlocked right now, so an unlock
        // that hasn't locked yet is still going.
        let now: Int64? = appOnScreen ? Int64(Date().timeIntervalSince1970 * 1000) : nil
        return spans(events, now: now).filter { $0.end > from && $0.start < to }
    }
}
