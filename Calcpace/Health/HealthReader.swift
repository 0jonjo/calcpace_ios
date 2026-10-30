import Foundation
import HealthKit

/// What changed in Apple Health since an anchor: the workouts added (or
/// written again), the ones deleted, and the anchor to ask from next time.
struct HealthChanges {
    let workouts: [HKWorkout]
    let deleted: [String]
    let anchor: HKQueryAnchor?
}

/// Reads Apple Health: workouts, their distance, climb and heart rate. Only
/// what the Apple Health card and the privacy page promise (time, distance,
/// duration, climb, heart rate); asking for any other type means changing
/// them too (App Review 5.1.3).
final class HealthReader {
    static let workoutType = HKObjectType.workoutType()
    static let distanceType = HKQuantityType(.distanceWalkingRunning)
    static let heartRateType = HKQuantityType(.heartRate)
    static let readTypes: Set<HKObjectType> = [workoutType, distanceType, heartRateType]

    static var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    let store: HKHealthStore

    init(store: HKHealthStore = HKHealthStore()) {
        self.store = store
    }

    /// The HealthKit sheet. Succeeds once the athlete answered it, whatever
    /// they allowed: HealthKit never tells an app what it may read.
    func requestAuthorization() async throws {
        try await store.requestAuthorization(toShare: [], read: Self.readTypes)
    }

    /// Every workout since `anchor`; with none, those that started after `start`.
    func changes(since anchor: HKQueryAnchor?, startingAfter start: Date?) async throws -> HealthChanges {
        let predicate = anchor == nil ? start.map { HKQuery.predicateForSamples(withStart: $0, end: nil, options: .strictStartDate) } : nil
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKAnchoredObjectQuery(type: Self.workoutType, predicate: predicate, anchor: anchor, limit: HKObjectQueryNoLimit) { _, samples, deleted, newAnchor, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: HealthChanges(
                    workouts: (samples ?? []).compactMap { $0 as? HKWorkout },
                    deleted: (deleted ?? []).map { WorkoutMapper.id($0.uuid) },
                    anchor: newAnchor
                ))
            }
            store.execute(query)
        }
    }

    func facts(_ workout: HKWorkout) async -> WorkoutFacts {
        let heart = await heartRate(during: workout)
        let metadata = workout.metadata ?? [:]
        return WorkoutFacts(
            id: workout.uuid,
            kind: Self.kind(workout.workoutActivityType),
            indoor: (metadata[HKMetadataKeyIndoorWorkout] as? NSNumber)?.boolValue ?? false,
            start: workout.startDate,
            end: workout.endDate,
            duration: workout.duration,
            distanceM: distance(of: workout),
            elevationGainM: (metadata[HKMetadataKeyElevationAscended] as? HKQuantity)?.doubleValue(for: .meter()),
            timeZone: metadata[HKMetadataKeyTimeZone] as? String,
            origin: workout.sourceRevision.source.bundleIdentifier,
            device: workout.device?.name,
            hrAvg: heart.average,
            hrMax: heart.maximum
        )
    }

    // MARK: Private

    private static func kind(_ type: HKWorkoutActivityType) -> WorkoutFacts.Kind {
        switch type {
        case .running: return .running
        case .walking: return .walking
        default: return .other
        }
    }

    private func distance(of workout: HKWorkout) -> Double? {
        if let sum = workout.statistics(for: Self.distanceType)?.sumQuantity() {
            return sum.doubleValue(for: .meter())
        }
        return workout.totalDistance?.doubleValue(for: .meter())
    }

    /// The workout's own figures when its app recorded them with it (the
    /// Apple Watch), else every heart rate sample of its time.
    private func heartRate(during workout: HKWorkout) async -> (average: Double?, maximum: Double?) {
        let unit = HKUnit.count().unitDivided(by: .minute())
        if let stats = workout.statistics(for: Self.heartRateType),
           let average = stats.averageQuantity() {
            return (average.doubleValue(for: unit), stats.maximumQuantity()?.doubleValue(for: unit))
        }

        let predicate = HKQuery.predicateForSamples(withStart: workout.startDate, end: workout.endDate, options: [])
        return await withCheckedContinuation { continuation in
            let query = HKStatisticsQuery(quantityType: Self.heartRateType, quantitySamplePredicate: predicate, options: [.discreteAverage, .discreteMax]) { _, stats, _ in
                continuation.resume(returning: (
                    stats?.averageQuantity()?.doubleValue(for: unit),
                    stats?.maximumQuantity()?.doubleValue(for: unit)
                ))
            }
            store.execute(query)
        }
    }
}
