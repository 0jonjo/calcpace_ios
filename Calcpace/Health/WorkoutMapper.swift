import Foundation

/// What HealthReader learned about one workout, before it is judged fit to
/// send. Free of HealthKit types so the rules are unit tested.
struct WorkoutFacts {
    enum Kind {
        case running
        case walking
        case other
    }

    let id: UUID
    let kind: Kind
    /// HKMetadataKeyIndoorWorkout: a run on a treadmill.
    let indoor: Bool
    let start: Date
    let end: Date
    /// The workout's own duration, its pauses already left out.
    let duration: TimeInterval
    let distanceM: Double?
    /// HKMetadataKeyElevationAscended, when the app that wrote it said.
    let elevationGainM: Double?
    /// HKMetadataKeyTimeZone: an identifier such as "America/Sao_Paulo".
    let timeZone: String?
    /// The bundle id of the app that wrote it ("com.strava.stravaride").
    let origin: String
    let device: String?
    let hrAvg: Double?
    let hrMax: Double?
    /// Its route, when its app saved one (and the athlete let the app read
    /// it); not read for a workout indoors.
    var route: [HealthRoute.Point]? = nil

    /// Read for a route: an outdoor run or walk, the only ones with a map.
    var mayHaveRoute: Bool {
        kind != .other && !indoor
    }
}

/// A workout from Apple Health → one entry of "sessions" in
/// POST /health_connect/sessions, the same JSON the Android app sends
/// (HcPayload.wire). The server checks it is plausible and drops Strava's
/// copy when Strava is connected (HealthConnect::SessionImporter); the app
/// only leaves out what is no run or walk, or has no distance.
enum WorkoutMapper {
    private static let maxDevice = 100

    /// What a sync does with a workout (HealthSync, PendingWorkouts).
    enum Judged: Equatable {
        /// Sent. `awaitsRoute`: an outdoor run or walk without its route
        /// yet, read again for it.
        case ready(WireSession, awaitsRoute: Bool)
        /// A run or walk without its distance yet: read again for it.
        case awaitsDistance
        /// Never sent: no run or walk, or a clock that will not do.
        case left
    }

    static func judge(_ facts: WorkoutFacts) -> Judged {
        guard facts.kind != .other, validClock(facts) else { return .left }
        guard let session = wire(facts) else { return .awaitsDistance }
        // A route there but unusable (a single fix, too long) never changes:
        // only one not saved yet is waited for.
        return .ready(session, awaitsRoute: facts.mayHaveRoute && facts.route == nil)
    }

    static func wire(_ facts: WorkoutFacts) -> WireSession? {
        let type: String
        switch facts.kind {
        case .running: type = facts.indoor ? "running_treadmill" : "running"
        case .walking: type = "walking"
        case .other: return nil
        }
        guard let distance = facts.distanceM, distance > 0, distance.isFinite else { return nil }
        guard validClock(facts) else { return nil }
        let duration = Int(facts.duration.rounded())
        let route = facts.mayHaveRoute ? facts.route.map { HealthRoute.thin(HealthRoute.clip($0, from: facts.start, to: facts.end)) } ?? [] : []

        return WireSession(
            id: id(facts.id),
            type: type,
            start: timestamp(facts.start),
            end: timestamp(facts.end),
            zoneOffset: facts.timeZone.flatMap { TimeZone(identifier: $0) }?.secondsFromGMT(for: facts.start),
            origin: facts.origin,
            device: facts.device.map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxDevice)) }.flatMap { $0.isEmpty ? nil : $0 },
            distanceM: distance,
            durationS: duration,
            hrAvg: beats(facts.hrAvg),
            hrMax: beats(facts.hrMax),
            elevationGainM: facts.elevationGainM.flatMap { $0 >= 0 && $0.isFinite ? $0 : nil },
            route: route.isEmpty ? nil : HealthRoute.wire(route)
        )
    }

    /// A distance sample its app saved apart from the workout.
    struct DistanceSample {
        let start: Date
        let end: Date
        let meters: Double
    }

    /// The samples of a workout's app over its time, when none were tied to
    /// it: each counted where its middle falls, so a sample at the seam of
    /// two back-to-back workouts counts once, and one saved over exactly the
    /// workout's time counts (HealthKit compares dates finer than they read
    /// back, so a strict window of that time leaves it out). Nil for none.
    static func meters(_ samples: [DistanceSample], from start: Date, to end: Date) -> Double? {
        guard end >= start else { return nil }
        let total = samples
            .filter { $0.meters.isFinite && $0.meters > 0 && $0.end >= $0.start }
            .filter { (start ... end).contains($0.start.addingTimeInterval($0.end.timeIntervalSince($0.start) / 2)) }
            .reduce(0) { $0 + $1.meters }
        return total > 0 ? total : nil
    }

    /// How a workout is named on the wire, in "sessions" and in "deleted"
    /// alike: the server matches the two by this exact string.
    static func id(_ uuid: UUID) -> String {
        uuid.uuidString.lowercased()
    }

    /// The server reads Ruby's Time.iso8601: "2026-10-30T12:00:00Z".
    static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    /// A whole second at least, its end after its start.
    private static func validClock(_ facts: WorkoutFacts) -> Bool {
        facts.duration.isFinite && facts.end > facts.start && Int(facts.duration.rounded()) > 0
    }

    private static func beats(_ value: Double?) -> Int? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return Int(value.rounded())
    }
}
