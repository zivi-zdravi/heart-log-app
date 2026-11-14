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
