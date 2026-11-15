import Foundation

/// Where a notification goes.
enum NotifyRoute: String, Codable, CaseIterable {
    case off, phone, band, both

    var label: String {
        switch self {
        case .off: return "Off"
        case .phone: return "Phone"
        case .band: return "Band buzz"
        case .both: return "Both"
        }
    }

    var short: String { self == .band ? "Band" : label }
    var toPhone: Bool { self == .phone || self == .both }
    var toBand: Bool { self == .band || self == .both }
}

/// Settings > Notifications (approved mockup). Saved in notify.json.
struct NotifySettings: Codable, Equatable {
    var lowBattery: NotifyRoute = .phone
    var lowBatteryAt = 20
    var charger: NotifyRoute = .off
    var goneQuiet: NotifyRoute = .phone
    var alarmNotSaved: NotifyRoute = .phone
    var noAlarmCheckIn: NotifyRoute = .off
    var windDown: NotifyRoute = .band
    var stepGoal: NotifyRoute = .phone
    var stepGoalCount = 8000
    var possibleActivity: NotifyRoute = .off
    var water: NotifyRoute = .band
    var waterEveryHours = 2
    var quietOn = true
    /// Minutes after midnight.
    var quietStart = 22 * 60
    var quietEnd = 7 * 60

    init() {}

    // Missing keys fall back to defaults, so adding a setting later never
    // wipes the ones already chosen.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = NotifySettings()
        lowBattery = try c.decodeIfPresent(NotifyRoute.self, forKey: .lowBattery) ?? d.lowBattery
        lowBatteryAt = try c.decodeIfPresent(Int.self, forKey: .lowBatteryAt) ?? d.lowBatteryAt
        charger = try c.decodeIfPresent(NotifyRoute.self, forKey: .charger) ?? d.charger
        goneQuiet = try c.decodeIfPresent(NotifyRoute.self, forKey: .goneQuiet) ?? d.goneQuiet
        alarmNotSaved = try c.decodeIfPresent(NotifyRoute.self, forKey: .alarmNotSaved) ?? d.alarmNotSaved
        noAlarmCheckIn = try c.decodeIfPresent(NotifyRoute.self, forKey: .noAlarmCheckIn) ?? d.noAlarmCheckIn
        windDown = try c.decodeIfPresent(NotifyRoute.self, forKey: .windDown) ?? d.windDown
        stepGoal = try c.decodeIfPresent(NotifyRoute.self, forKey: .stepGoal) ?? d.stepGoal
        stepGoalCount = try c.decodeIfPresent(Int.self, forKey: .stepGoalCount) ?? d.stepGoalCount
        possibleActivity = try c.decodeIfPresent(NotifyRoute.self, forKey: .possibleActivity) ?? d.possibleActivity
        water = try c.decodeIfPresent(NotifyRoute.self, forKey: .water) ?? d.water
        waterEveryHours = try c.decodeIfPresent(Int.self, forKey: .waterEveryHours) ?? d.waterEveryHours
        quietOn = try c.decodeIfPresent(Bool.self, forKey: .quietOn) ?? d.quietOn
        quietStart = try c.decodeIfPresent(Int.self, forKey: .quietStart) ?? d.quietStart
        quietEnd = try c.decodeIfPresent(Int.self, forKey: .quietEnd) ?? d.quietEnd
    }

    var anyPhone: Bool {
        [lowBattery, charger, goneQuiet, alarmNotSaved, noAlarmCheckIn, windDown, stepGoal, possibleActivity, water].contains { $0.toPhone }
    }
}

/// What has already been sent, so each alert fires once when it should.
struct NotifyState: Codable, Equatable {
    var lowBatterySent = false
    var lastWaterReminder: Int64?
    /// Day keys an alert was last sent for.
    var stepGoalDay: String?
    var windDownDay: String?
    var checkInDay: String?
    var notSavedDay: String?
    /// Start times (ms) of activity spans already announced.
    var announcedActivities: [Int64] = []
}

/// The decisions behind each notification, kept pure so they're tested.
enum NotifyRules {
    /// Whether a minute of the day falls in quiet hours (which may cross midnight).
    static func isQuiet(_ minute: Int, _ s: NotifySettings) -> Bool {
        guard s.quietOn, s.quietStart != s.quietEnd else { return false }
        if s.quietStart < s.quietEnd { return minute >= s.quietStart && minute < s.quietEnd }
        return minute >= s.quietStart || minute < s.quietEnd
    }

    /// Low battery fires once on the way down, and re-arms after charging
    /// back above the threshold plus 5.
    static func lowBattery(level: Int, at threshold: Int, sent: Bool) -> (fire: Bool, sent: Bool) {
        if level < threshold { return (!sent, true) }
        if level >= threshold + 5 { return (false, false) }
        return (false, sent)
    }

    /// Water reminder: due when neither a glass nor a reminder happened in the
    /// last `everyHours`, counting from when quiet hours ended this morning.
    static func waterDue(now: Int64, lastGlass: Int64?, lastReminder: Int64?, wokeAt: Int64, everyHours: Int) -> Bool {
        let since = max(lastGlass ?? 0, lastReminder ?? 0, wokeAt)
        return now - since >= Int64(everyHours) * 3_600_000
    }

    /// No-alarm check-in: tomorrow is normally an alarm day, but no alarm
    /// will go off tomorrow (it was cancelled).
    static func checkInDue(schedule: AlarmSchedule, now: Date, calendar: Calendar = .current) -> Bool {
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) else { return false }
        let day = schedule.days[AlarmSchedule.index(of: tomorrow, calendar: calendar)]
        guard day.on else { return false }
        guard let next = schedule.next(after: now, calendar: calendar) else { return true }
        return !calendar.isDate(next, inSameDayAs: tomorrow)
    }

    /// Wind-down time: target bedtime (usual wake minus tonight's need) less 45 minutes.
    static func windDownMinute(usualWakeMinute: Double, needMinutes: Double) -> Int {
        let bed = (usualWakeMinute - needMinutes).truncatingRemainder(dividingBy: 1440)
        let wind = bed - 45
        return Int(((wind.truncatingRemainder(dividingBy: 1440)) + 1440).truncatingRemainder(dividingBy: 1440))
    }
}
