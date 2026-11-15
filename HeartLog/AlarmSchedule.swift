import Foundation

/// One weekday's wake alarm.
struct AlarmDay: Codable, Equatable {
    var on: Bool
    /// Minutes after midnight, local time.
    var minutes: Int
}

/// The weekly band alarm. The band holds one alarm at a time, so Zdravlje
/// keeps the schedule and puts the next upcoming wake on the band.
struct AlarmSchedule: Codable, Equatable {
    /// Monday first, Sunday last.
    var days: [AlarmDay]
    /// Occurrences at or before this time are skipped ("cancel the next alarm").
    var skipThrough: Date?

    static let `default` = AlarmSchedule(days: Array(repeating: AlarmDay(on: false, minutes: 7 * 60), count: 7), skipThrough: nil)

    static let weekdayNames = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

    var anyOn: Bool { days.contains(where: \.on) }

    /// Index into `days` (Monday = 0) for a date.
    static func index(of date: Date, calendar: Calendar) -> Int {
        (calendar.component(.weekday, from: date) + 5) % 7
    }

    /// The next alarm strictly after `now`, honoring a skipped occurrence.
    func next(after now: Date, calendar: Calendar = .current) -> Date? {
        guard days.count == 7, anyOn else { return nil }
        let today = calendar.startOfDay(for: now)
        for offset in 0...8 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: today) else { continue }
            let d = days[Self.index(of: day, calendar: calendar)]
            guard d.on else { continue }
            var parts = calendar.dateComponents([.year, .month, .day], from: day)
            parts.hour = d.minutes / 60
            parts.minute = d.minutes % 60
            guard let t = calendar.date(from: parts), t > now else { continue }
            if let skip = skipThrough, t <= skip { continue }
            return t
        }
        return nil
    }

    /// "7:00" style label for a day's time.
    static func label(minutes: Int) -> String {
        String(format: "%d:%02d", minutes / 60, minutes % 60)
    }
}
