import AppIntents
import Foundation

/// Step counts sent in by an iPhone Shortcut, one number per day, kept on this phone.
enum StepsLog {
    struct Entry: Codable { var count: Int; var at: Int64 }

    private static var url: URL { Store.shared.dir.appendingPathComponent("steps.json") }

    static func key(_ day: Date) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: day)
    }

    static func all() -> [String: Entry] {
        (try? JSONDecoder().decode([String: Entry].self, from: Data(contentsOf: url))) ?? [:]
    }

    static func entry(for day: Date) -> Entry? { all()[key(day)] }

    static func save(_ count: Int, for day: Date) {
        var log = all()
        log[key(day)] = Entry(count: max(0, count), at: Store.nowMs())
        JSONFile.write(log, to: url)
    }

    static var lastUpdate: Date? {
        all().values.map(\.at).max().map { Date(timeIntervalSince1970: Double($0) / 1000) }
    }
}

struct LogStepsIntent: AppIntent {
    static var title: LocalizedStringResource = "Log Steps in Zdravlje"
    static var description = IntentDescription("Saves today's step count in Zdravlje.")
    static var openAppWhenRun = false

    @Parameter(title: "Steps")
    var steps: Double

    func perform() async throws -> some IntentResult {
        StepsLog.save(Int(steps.rounded()), for: Date())
        return .result()
    }
}
