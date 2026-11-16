import Foundation
import HealthKit

/// Reads the iPhone's step count from Apple Health. Read-only; nothing is written to Health.
@MainActor
final class StepsProvider: ObservableObject {
    @Published var steps: Int?
    @Published var note = ""
    private let store = HKHealthStore()

    func load(day: Date) async {
        if let logged = StepsLog.entry(for: day) {
            steps = logged.count
            note = "From Shortcut, \(Date(timeIntervalSince1970: Double(logged.at) / 1000).formatted(date: .omitted, time: .shortened))"
            return
        }
        guard HKHealthStore.isHealthDataAvailable(), let type = HKObjectType.quantityType(forIdentifier: .stepCount) else {
            steps = nil
            note = "Health not available"
            return
        }
        do {
            try await store.requestAuthorization(toShare: Set<HKSampleType>(), read: Set([type as HKObjectType]))
        } catch {
            steps = nil
            if StepsLog.all().isEmpty {
                note = "Set up the steps Shortcut in Settings"
            } else {
                note = Calendar.current.isDateInToday(day) ? "Updates when your Shortcut runs" : "No steps logged this day"
            }
            return
        }
        let end = min(Calendar.current.date(byAdding: .day, value: 1, to: day) ?? day, Date())
        let predicate = HKQuery.predicateForSamples(withStart: day, end: end, options: .strictStartDate)
        let healthStore = store
        let total: Int? = await withCheckedContinuation { cont in
            let query = HKStatisticsQuery(quantityType: type, quantitySamplePredicate: predicate, options: .cumulativeSum) { _, stats, _ in
                cont.resume(returning: stats?.sumQuantity().map { Int($0.doubleValue(for: .count())) })
            }
            healthStore.execute(query)
        }
        steps = total ?? 0
        note = total == nil ? "No steps found. Check Health access in Settings." : ""
    }
}

extension StepsProvider {
    /// Steps for each day from `from` through `to` (start-of-day dates). A day logged by the
    /// Shortcut uses that number; other days come from Apple Health. Days with nothing are left out.
    static func daily(from: Date, to: Date) async -> [Date: Int] {
        let cal = Calendar.current
        let start = cal.startOfDay(for: from)
        let end = min(cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: to)) ?? to, Date())
        var out: [Date: Int] = [:]
        let store = HKHealthStore()
        if HKHealthStore.isHealthDataAvailable(), let type = HKObjectType.quantityType(forIdentifier: .stepCount),
           (try? await store.requestAuthorization(toShare: Set<HKSampleType>(), read: Set([type as HKObjectType]))) != nil {
            let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
            let health: [Date: Int] = await withCheckedContinuation { cont in
                let q = HKStatisticsCollectionQuery(quantityType: type, quantitySamplePredicate: predicate, options: .cumulativeSum,
                                                    anchorDate: start, intervalComponents: DateComponents(day: 1))
                q.initialResultsHandler = { _, results, _ in
                    var days: [Date: Int] = [:]
                    results?.enumerateStatistics(from: start, to: end) { stats, _ in
                        if let v = stats.sumQuantity()?.doubleValue(for: .count()), v > 0 { days[cal.startOfDay(for: stats.startDate)] = Int(v) }
                    }
                    cont.resume(returning: days)
                }
                store.execute(q)
            }
            out = health
        }
        let logged = StepsLog.all()
        var d = start
        while d < end {
            if let e = logged[StepsLog.key(d)] { out[d] = e.count }
            guard let next = cal.date(byAdding: .day, value: 1, to: d) else { break }
            d = next
        }
        return out
    }
}
