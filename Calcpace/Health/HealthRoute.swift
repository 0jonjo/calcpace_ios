import Foundation

/// The map of a workout: the route its app saved with it in Apple Health
/// (`HKWorkoutRoute`, read by HealthReader), sent with the session as
/// `route`, which the site turns into the run's map (HealthConnect::
/// SessionImporter#route_polyline). The Android app's HcRoutes, without the
/// question: HealthKit asks for every route at once, in the sheet, and hands
/// them to a background read too.
///
/// Free of HealthKit types so it is unit tested.
enum HealthRoute {
    struct Point: Equatable {
        let time: Date
        let lat: Double
        let lon: Double
    }

    /// One point every `spacing` at most.
    static let spacing: TimeInterval = 5
    /// HealthConnect::SessionImporter::MAX_ROUTE_POINTS: past it, the site
    /// drops the route whole.
    static let maxPoints = 20_000
    /// HealthConnect::UploadsController::MAX_ROUTE_POINTS: past it, the
    /// sessions of an upload come without their route (HealthPayload.batches).
    static let maxPointsPerUpload = 40_000

    /// HealthConnect::SessionImporter::ROUTE_SLACK: the site drops a route
    /// whole if a single point falls further than this outside the workout.
    static let slack: TimeInterval = 60

    /// The points within the workout's time, `slack` either side: a fix an
    /// app saved before the start or after the end would cost the map.
    static func clip(_ points: [Point], from start: Date, to end: Date) -> [Point] {
        let window = start.addingTimeInterval(-slack) ... end.addingTimeInterval(slack)
        return points.filter { window.contains($0.time) }
    }

    /// A point every `spacing` at most, the first and the last always: what
    /// the site keeps of a route anyway (Recording#polyline), at a fraction
    /// of the upload. A route still longer than the site takes goes not at
    /// all, rather than cut; so does one of a single point.
    static func thin(_ points: [Point]) -> [Point] {
        let sorted = points
            .filter { (-90.0 ... 90.0).contains($0.lat) && (-180.0 ... 180.0).contains($0.lon) && $0.time.timeIntervalSince1970.isFinite }
            .sorted { $0.time < $1.time }
        guard let first = sorted.first, let last = sorted.last else { return [] }
        var kept = [first]
        for point in sorted.dropFirst() where point.time.timeIntervalSince(kept[kept.count - 1].time) >= spacing {
            kept.append(point)
        }
        if kept[kept.count - 1] != last { kept.append(last) }
        return kept.count < 2 || kept.count > maxPoints ? [] : kept
    }

    /// [epoch seconds, lat, lon], as the site reads a route.
    static func wire(_ points: [Point]) -> [WirePoint] {
        points.map { WirePoint(time: Int($0.time.timeIntervalSince1970.rounded(.down)), lat: $0.lat, lon: $0.lon) }
    }
}

/// One entry of a session's "route": `[1793000000, -5.79, -35.2]`.
struct WirePoint: Encodable, Equatable {
    let time: Int
    let lat: Double
    let lon: Double

    func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(time)
        try container.encode(lat)
        try container.encode(lon)
    }
}
