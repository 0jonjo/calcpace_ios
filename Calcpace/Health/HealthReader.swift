import CoreLocation
import Foundation
import HealthKit

/// What changed in Apple Health since an anchor: the workouts added (or
/// written again), the ones deleted, and the anchor to ask from next time.
struct HealthChanges {
    let workouts: [HKWorkout]
    let deleted: [String]
    let anchor: HKQueryAnchor?
}

/// Reads Apple Health: workouts, their distance, climb, heart rate and
/// route. Only what the Apple Health card and the privacy page promise
/// (time, distance, duration, climb, heart rate, route); asking for any
/// other type means changing them too (App Review 5.1.3).
final class HealthReader {
    static let workoutType = HKObjectType.workoutType()
    static let distanceType = HKQuantityType(.distanceWalkingRunning)
    static let heartRateType = HKQuantityType(.heartRate)
    static let routeType = HKSeriesType.workoutRoute()
    static let readTypes: Set<HKObjectType> = [workoutType, distanceType, heartRateType, routeType]

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

    /// The workouts still in Apple Health among `ids` (PendingWorkouts).
    func workouts(ids: Set<UUID>) async throws -> [HKWorkout] {
        guard !ids.isEmpty else { return [] }
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(sampleType: Self.workoutType, predicate: HKQuery.predicateForObjects(with: ids), limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: (samples ?? []).compactMap { $0 as? HKWorkout })
            }
            store.execute(query)
        }
    }

    func facts(_ workout: HKWorkout) async -> WorkoutFacts {
        let heart = await heartRate(during: workout)
        let distance = await distance(of: workout)
        let metadata = workout.metadata ?? [:]
        let kind = Self.kind(workout.workoutActivityType)
        let indoor = (metadata[HKMetadataKeyIndoorWorkout] as? NSNumber)?.boolValue ?? false
        var points: [HealthRoute.Point]?
        if kind != .other, !indoor {
            points = await route(of: workout)
        }
        return WorkoutFacts(
            id: workout.uuid,
            kind: kind,
            indoor: indoor,
            start: workout.startDate,
            end: workout.endDate,
            duration: workout.duration,
            distanceM: distance,
            elevationGainM: (metadata[HKMetadataKeyElevationAscended] as? HKQuantity)?.doubleValue(for: .meter()),
            timeZone: metadata[HKMetadataKeyTimeZone] as? String,
            origin: workout.sourceRevision.source.bundleIdentifier,
            device: workout.device?.name,
            hrAvg: heart.average,
            hrMax: heart.maximum,
            route: points
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

    /// The workout's own sum; else the distance samples its app tied to it
    /// after saving it; else its app's samples over its time. A workout
    /// still without distance is left out (WorkoutMapper) and not read again.
    private func distance(of workout: HKWorkout) async -> Double? {
        if let sum = workout.statistics(for: Self.distanceType)?.sumQuantity() {
            return sum.doubleValue(for: .meter())
        }
        if let total = workout.totalDistance?.doubleValue(for: .meter()), total > 0 {
            return total
        }
        if let tied = await sum(of: Self.distanceType, matching: HKQuery.predicateForObjects(from: workout)), tied > 0 {
            return tied
        }
        let window = NSCompoundPredicate(andPredicateWithSubpredicates: [
            HKQuery.predicateForSamples(withStart: workout.startDate, end: workout.endDate, options: [.strictStartDate, .strictEndDate]),
            HKQuery.predicateForObjects(from: workout.sourceRevision.source)
        ])
        return await sum(of: Self.distanceType, matching: window)
    }

    private func sum(of type: HKQuantityType, matching predicate: NSPredicate) async -> Double? {
        await withCheckedContinuation { continuation in
            let query = HKStatisticsQuery(quantityType: type, quantitySamplePredicate: predicate, options: .cumulativeSum) { _, stats, _ in
                continuation.resume(returning: stats?.sumQuantity()?.doubleValue(for: .meter()))
            }
            store.execute(query)
        }
    }

    /// Every location of the routes its app tied to the workout (one, or a
    /// few when the GPS dropped out), or nil: none yet, routes not allowed
    /// (HealthKit then says there is none), or one that failed to read,
    /// rather than half a map.
    private func route(of workout: HKWorkout) async -> [HealthRoute.Point]? {
        let routes: [HKWorkoutRoute] = await withCheckedContinuation { continuation in
            let query = HKSampleQuery(sampleType: Self.routeType, predicate: HKQuery.predicateForObjects(from: workout), limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, _ in
                continuation.resume(returning: (samples ?? []).compactMap { $0 as? HKWorkoutRoute })
            }
            store.execute(query)
        }
        guard !routes.isEmpty else { return nil }
        var points: [HealthRoute.Point] = []
        for route in routes {
            guard let some = await locations(of: route) else { return nil }
            points += some
        }
        return points.isEmpty ? nil : points
    }

    /// HKWorkoutRouteQuery hands the locations over in batches, the last
    /// one with `done`.
    private func locations(of route: HKWorkoutRoute) async -> [HealthRoute.Point]? {
        await withCheckedContinuation { continuation in
            let collected = RouteBatches()
            let query = HKWorkoutRouteQuery(route: route) { _, locations, done, error in
                if let result = collected.add(locations ?? [], done: done, failed: error != nil) {
                    continuation.resume(returning: result)
                }
            }
            store.execute(query)
        }
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

/// The locations of one HKWorkoutRouteQuery, batch after batch. Answers
/// once: the points on the last batch, nil on an error; nothing after.
private final class RouteBatches {
    private let lock = NSLock()
    private var points: [HealthRoute.Point] = []
    private var answered = false

    func add(_ locations: [CLLocation], done: Bool, failed: Bool) -> [HealthRoute.Point]?? {
        lock.lock()
        defer { lock.unlock() }
        guard !answered else { return nil }
        if failed {
            answered = true
            return .some(nil)
        }
        // A negative accuracy is a location without a valid fix.
        points += locations.filter { $0.horizontalAccuracy >= 0 }.map {
            HealthRoute.Point(time: $0.timestamp, lat: $0.coordinate.latitude, lon: $0.coordinate.longitude)
        }
        guard done else { return nil }
        answered = true
        return .some(points)
    }
}
