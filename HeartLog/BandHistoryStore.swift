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

    var days: [String: BandDay] { lock.lock(); defer { lock.unlock() }; return data.days }

    func day(_ key: String) -> BandDay? { days[key] }

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
        let (merged, changed) = OpenStrapImport.merge(incoming, into: data)
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
    /// Phone use logged by any recording between two times.
    static func read(from: Int64, to: Int64) -> [Span] {
        var events: [(Int64, String)] = []
        for id in Store.shared.sessions() {
            guard let started = Int64(id.dropFirst()), started <= to else { continue }
            let csv = (try? String(contentsOf: Store.shared.eventsURL(id), encoding: .utf8)) ?? ""
            events += parse(csv).filter { ($0.1 == "unlocked" || $0.1 == "locked") && $0.0 >= from - 3_600_000 && $0.0 <= to }
        }
        return spans(events).filter { $0.end > from && $0.start < to }
    }
}
