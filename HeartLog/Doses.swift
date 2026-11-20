import Foundation

/// Supplements (in Meals) and medications (in the Body log). Each is set up
/// once: name, dose, and either a group or a time of its own.
enum DoseKind: String, Codable, CaseIterable {
    case supplement, medication
}

struct DoseItem: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var kind: DoseKind
    var name: String
    var amount: Double
    var unit: String
    /// Calories per dose; supplements only. Counted in Meals when taken.
    var kcal: Double?
    /// The group this belongs to, or nil for an item on its own.
    var group: String?
    /// Minutes after midnight, for an item on its own.
    var time: Int = 8 * 60
    var reminder: NotifyRoute = .phone
}

struct DoseGroup: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var kind: DoseKind
    var name: String
    /// Minutes after midnight.
    var time: Int
    var reminder: NotifyRoute = .phone
}

struct DoseData: Codable, Equatable {
    var items: [DoseItem] = []
    var groups: [DoseGroup] = []
    /// Day key ("yyyy-MM-dd") to item id to when it was taken (Unix ms).
    var taken: [String: [String: Int64]] = [:]
    /// Slot id to the day key its reminder last went out.
    var reminded: [String: String] = [:]
    var supplementsOn = true
    var medicationsOn = false
    var supplementsInAsk = true
    var medicationsInAsk = false

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = DoseData()
        items = try c.decodeIfPresent([DoseItem].self, forKey: .items) ?? d.items
        groups = try c.decodeIfPresent([DoseGroup].self, forKey: .groups) ?? d.groups
        taken = try c.decodeIfPresent([String: [String: Int64]].self, forKey: .taken) ?? d.taken
        reminded = try c.decodeIfPresent([String: String].self, forKey: .reminded) ?? d.reminded
        supplementsOn = try c.decodeIfPresent(Bool.self, forKey: .supplementsOn) ?? d.supplementsOn
        medicationsOn = try c.decodeIfPresent(Bool.self, forKey: .medicationsOn) ?? d.medicationsOn
        supplementsInAsk = try c.decodeIfPresent(Bool.self, forKey: .supplementsInAsk) ?? d.supplementsInAsk
        medicationsInAsk = try c.decodeIfPresent(Bool.self, forKey: .medicationsInAsk) ?? d.medicationsInAsk
    }

    func isOn(_ k: DoseKind) -> Bool { k == .supplement ? supplementsOn : medicationsOn }
}

/// One row on screen and one reminder: a group, or an item on its own.
struct DoseSlot: Equatable, Identifiable {
    var id: String
    var name: String
    var time: Int
    var reminder: NotifyRoute
    var items: [DoseItem]
    var isGroup: Bool
}

enum DoseMath {
    static let units = ["mg", "g", "mcg", "IU", "mL", "capsule", "tablet", "scoop", "drop", "puff", "unit"]

    /// Groups and lone items of one kind, in time order. Empty groups are left out.
    static func slots(_ d: DoseData, _ kind: DoseKind) -> [DoseSlot] {
        var out: [DoseSlot] = []
        for g in d.groups where g.kind == kind {
            let items = d.items.filter { $0.kind == kind && $0.group == g.id }
            if !items.isEmpty { out.append(DoseSlot(id: g.id, name: g.name, time: g.time, reminder: g.reminder, items: items, isGroup: true)) }
        }
        let groupIDs = Set(d.groups.map(\.id))
        for i in d.items where i.kind == kind && (i.group == nil || !groupIDs.contains(i.group!)) {
            out.append(DoseSlot(id: i.id, name: i.name, time: i.time, reminder: i.reminder, items: [i], isGroup: false))
        }
        return out.sorted { $0.time == $1.time ? $0.name < $1.name : $0.time < $1.time }
    }

    static func isTaken(_ d: DoseData, day: String, item: String) -> Bool { d.taken[day]?[item] != nil }

    static func allTaken(_ d: DoseData, day: String, _ slot: DoseSlot) -> Bool {
        slot.items.allSatisfy { isTaken(d, day: day, item: $0.id) }
    }

    /// How many of the day's items are checked off, out of how many.
    static func counts(_ d: DoseData, day: String, _ kind: DoseKind) -> (taken: Int, total: Int) {
        let items = slots(d, kind).flatMap(\.items)
        return (items.filter { isTaken(d, day: day, item: $0.id) }.count, items.count)
    }

    /// Calories from supplements taken that day.
    static func kcal(_ d: DoseData, day: String) -> Double {
        d.items.filter { $0.kind == .supplement && d.supplementsOn && isTaken(d, day: day, item: $0.id) }.reduce(0) { $0 + ($1.kcal ?? 0) }
    }

    /// The slot a double-tap should check off: not all taken, and its time
    /// was in the last hour or comes within 30 minutes. Closest first.
    static func due(_ d: DoseData, day: String, minute: Int) -> DoseSlot? {
        let kinds = DoseKind.allCases.filter { d.isOn($0) }
        let open = kinds.flatMap { slots(d, $0) }.filter { !allTaken(d, day: day, $0) }
        let near = open.filter { minute - $0.time <= 60 && $0.time - minute <= 30 }
        return near.min { abs($0.time - minute) < abs($1.time - minute) }
    }

    /// Slots whose reminder should go out now: on, time reached within the
    /// last hour, not yet reminded today, and not already checked off.
    static func remindersDue(_ d: DoseData, day: String, minute: Int) -> [DoseSlot] {
        DoseKind.allCases.filter { d.isOn($0) }.flatMap { slots(d, $0) }.filter {
            $0.reminder != .off && minute >= $0.time && minute - $0.time < 60
                && d.reminded[$0.id] != day && !allTaken(d, day: day, $0)
        }
    }

    static func doseText(_ i: DoseItem) -> String {
        let n = i.amount == i.amount.rounded() ? String(Int(i.amount)) : String(format: "%g", i.amount)
        return "\(n) \(i.unit)"
    }

    static func timeText(_ minute: Int) -> String {
        let h = minute / 60, m = minute % 60
        let hh = h % 12 == 0 ? 12 : h % 12
        return String(format: "%d:%02d %@", hh, m, h < 12 ? "AM" : "PM")
    }
}
