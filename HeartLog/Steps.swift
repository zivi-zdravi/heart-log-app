import Foundation
import HealthKit

/// Reads the iPhone's step count from Apple Health. Read-only; nothing is written to Health.
@MainActor
final class StepsProvider: ObservableObject {
    @Published var steps: Int?
    @Published var note = ""
    private let store = HKHealthStore()

    func load(day: Date) async {
        guard HKHealthStore.isHealthDataAvailable(), let type = HKObjectType.quantityType(forIdentifier: .stepCount) else {
            steps = nil
            note = "Health not available"
            return
        }
        do {
            try await store.requestAuthorization(toShare: Set<HKSampleType>(), read: Set([type as HKObjectType]))
        } catch {
            steps = nil
            note = "Health access unavailable"
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
