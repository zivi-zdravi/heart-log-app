import Foundation

/// The weekly alarm schedule and what was last put on the band, saved in
/// alarm.json (included in backups).
final class AlarmStore: ObservableObject {
    static let shared = AlarmStore()
    static let fileName = "alarm.json"

    struct Armed: Codable, Equatable {
        /// Wall-clock wake time we asked the band for.
        var wake: Date
        /// The band answered success.
        var confirmed: Bool
    }

    private struct Saved: Codable {
        var schedule: AlarmSchedule
        var armed: Armed?
    }

    @Published var schedule: AlarmSchedule {
        didSet { if schedule != oldValue { save(); BandLink.shared.alarmScheduleChanged() } }
    }
    @Published var armed: Armed? {
        didSet { if armed != oldValue { save() } }
    }

    private static var url: URL { Store.shared.dir.appendingPathComponent(fileName) }

    private init() {
        let saved = try? JSONDecoder().decode(Saved.self, from: Data(contentsOf: Self.url))
        schedule = saved?.schedule ?? .default
        armed = saved?.armed
    }

    /// Re-reads alarm.json after a restore.
    func reload() {
        let saved = try? JSONDecoder().decode(Saved.self, from: Data(contentsOf: Self.url))
        schedule = saved?.schedule ?? .default
        armed = saved?.armed
    }

    var next: Date? { schedule.next(after: Date()) }

    private func save() {
        JSONFile.write(Saved(schedule: schedule, armed: armed), to: Self.url)
    }
}
