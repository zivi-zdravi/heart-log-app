import Foundation

/// What a double-tap on the band does.
enum TapAction: String, Codable, CaseIterable {
    case nothing
    case logWater
    case activity

    var title: String {
        switch self {
        case .nothing: return "Do nothing"
        case .logWater: return "Log a glass of water"
        case .activity: return "Start or stop an activity"
        }
    }

    var detail: String {
        switch self {
        case .nothing: return "Taps are ignored."
        case .logWater: return "Adds one glass to today's water on Meals."
        case .activity: return "Same as Start on the Today screen."
        }
    }
}

struct WaterDay: Codable, Equatable {
    var glasses: Int = 0
    /// Unix ms of the last glass added.
    var lastAt: Int64?
    var lastFromTap: Bool?
}

/// Water goal, glass size, each day's glasses, and the double-tap action.
/// Saved as water.json (included in backups).
struct WaterData: Codable, Equatable {
    var goalOz: Int = 64
    var glassOz: Int = 8
    var tapAction: TapAction = .logWater
    var days: [String: WaterDay] = [:]
    /// Unix ms and action of the last double-tap that did something.
    var lastTapAt: Int64?
    var lastTapAction: TapAction?

    static let goalRange = 8...256
    static let glassRange = 2...32

    func ounces(_ key: String) -> Int { (days[key]?.glasses ?? 0) * glassOz }

    mutating func add(_ key: String, at ms: Int64, fromTap: Bool) {
        var d = days[key] ?? WaterDay()
        d.glasses += 1
        d.lastAt = ms
        d.lastFromTap = fromTap
        days[key] = d
    }

    mutating func remove(_ key: String) {
        guard var d = days[key], d.glasses > 0 else { return }
        d.glasses -= 1
        if d.glasses == 0 { d.lastAt = nil; d.lastFromTap = nil }
        days[key] = d
    }

    /// "40 / 64 oz": short enough to stay on one line at three digits.
    func label(_ key: String) -> String { "\(ounces(key)) / \(goalOz) oz" }
}

/// When a double-tap from the band should do something.
enum TapGuard {
    /// Taps older than this (by the band's own clock) are replays from a
    /// history drain, not a tap happening now.
    static let maxAge: Double = 6
    /// One physical tap can arrive as more than one event.
    static let debounce: Double = 2
    /// Taps around the alarm are you stopping the buzz, not logging anything.
    static let beforeAlarm: Double = 60
    static let afterAlarm: Double = 600
    /// After the band reports the alarm fired (snoozes, a late fire).
    static let afterFired: Double = 300

    /// All times are phone-clock Unix seconds except `tapBandSec`, which is
    /// the band's own timestamp (converted with `clockOffset`, band minus phone).
    static func shouldAct(tapBandSec: UInt32, now: Double, clockOffset: Int?,
                          lastActed: Double?, alarm: Date?, alarmFired: Date?) -> Bool {
        // Skip the age check when the band's clock is unset or unknown.
        if tapBandSec >= 1_577_836_800, let offset = clockOffset {
            let tapPhone = Double(Int(tapBandSec) - offset)
            if now - tapPhone > maxAge { return false }
        }
        if let last = lastActed, now - last < debounce { return false }
        if let a = alarm?.timeIntervalSince1970, now >= a - beforeAlarm, now <= a + afterAlarm { return false }
        if let f = alarmFired?.timeIntervalSince1970, now >= f, now - f <= afterFired { return false }
        return true
    }
}
