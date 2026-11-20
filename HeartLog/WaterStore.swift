import Foundation

/// water.json: water goal, glass size, glasses per day, and the double-tap action.
final class WaterStore: ObservableObject {
    static let shared = WaterStore()
    static let fileName = "water.json"

    @Published private(set) var data: WaterData

    private static var url: URL { Store.shared.dir.appendingPathComponent(fileName) }

    private init() {
        data = (try? JSONDecoder().decode(WaterData.self, from: Data(contentsOf: Self.url))) ?? WaterData()
    }

    func reload() {
        data = (try? JSONDecoder().decode(WaterData.self, from: Data(contentsOf: Self.url))) ?? WaterData()
    }

    func change(_ edit: (inout WaterData) -> Void) {
        var d = data
        edit(&d)
        guard d != data else { return }
        data = d
        JSONFile.write(d, to: Self.url)
    }

    func addGlass(_ key: String, fromTap: Bool = false) {
        change { $0.add(key, at: Store.nowMs(), fromTap: fromTap) }
    }

    func removeGlass(_ key: String) {
        change { $0.remove(key) }
    }

    var goalOz: Int {
        get { data.goalOz }
        set { change { $0.goalOz = min(max(newValue, WaterData.goalRange.lowerBound), WaterData.goalRange.upperBound) } }
    }

    var glassOz: Int {
        get { data.glassOz }
        set { change { $0.glassOz = min(max(newValue, WaterData.glassRange.lowerBound), WaterData.glassRange.upperBound) } }
    }

    var tapAction: TapAction {
        get { data.tapAction }
        set {
            change { $0.tapAction = newValue }
            BandLink.shared.tapActionChanged()
        }
    }

    /// Runs the chosen action for a double-tap that passed TapGuard.
    func performTap() {
        let action = data.tapAction
        switch action {
        case .nothing:
            return
        case .logWater:
            addGlass(DayEngine.shared.key(Date()), fromTap: true)
        case .activity:
            let acts = ActivityStore.shared
            if let current = acts.current { acts.finish(current.id) } else { acts.start("Other") }
        case .doses:
            // Nothing due means nothing happens, and no confirming buzz.
            guard DoseStore.shared.markDue() != nil else { return }
            BandLink.shared.buzz("dose")
        }
        change {
            $0.lastTapAt = Store.nowMs()
            $0.lastTapAction = action
        }
    }
}
