import Foundation

/// Workouts read before Apple Health held all of them, by id, read again by
/// id on every sync: the anchor only watches the workouts themselves, so
/// what their app saves after them never comes back on its own. The Android
/// app's HcPending:
///
/// - `.distance`: no distance yet (an app that ties its distance samples to
///   the workout after saving it). Not sent until it has one.
/// - `.route`: sent, but an outdoor run or walk without its route yet (an
///   app that saves the route after the workout, as HKWorkoutRouteBuilder
///   does). Sent again once the route is there; the site fills the map of
///   the run it already has (SessionImporter#fill_map).
///
/// Each is given up on `maxAge` after it was first seen. Pure functions
/// over an immutable map, so they are unit tested.
enum PendingWorkouts {
    enum Reason: String, Codable {
        case distance
        case route
    }

    struct Entry: Codable, Equatable {
        /// Epoch second of the first sighting, whatever the reason since.
        let since: Int
        let reason: Reason
    }

    typealias List = [String: Entry]

    static let maxAge = 48 * 3600
    static let maxEntries = 100

    /// What a sync does with one workout it judged: the session to send, if
    /// any, and what it waits for next (nil: nothing, off the list).
    /// `waiting`: its reason on the list before; `changed`: the anchor
    /// brought it (new or written again), rather than a read by id.
    static func next(_ judged: WorkoutMapper.Judged, waiting: Reason?, changed: Bool) -> (send: WireSession?, wait: Reason?) {
        let sent = !changed && waiting == .route
        switch judged {
        case let .ready(session, awaitsRoute):
            guard awaitsRoute else { return (session, nil) }
            // Sent once already, unchanged since: read again only for its route.
            return (sent ? nil : session, .route)
        case .awaitsDistance:
            // Sent already, and its distance failed to read this time (the
            // phone locked mid-sync): still only its route is missing.
            return (nil, sent ? .route : .distance)
        case .left:
            return (nil, nil)
        }
    }

    /// `id` waits for `reason`; one already waiting keeps its first sighting.
    /// Past `maxEntries`, those waiting for a route go first (they only lose
    /// a map; one waiting for its distance was never sent), the oldest first.
    static func mark(_ list: List, _ id: String, _ reason: Reason, now: Int) -> List {
        var list = list
        list[id] = Entry(since: list[id]?.since ?? now, reason: reason)
        guard list.count > maxEntries else { return list }
        let kept = list.sorted { a, b in
            if a.value.reason != b.value.reason { return a.value.reason == .distance }
            if a.value.since != b.value.since { return a.value.since > b.value.since }
            return a.key < b.key
        }.prefix(maxEntries)
        return Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
    }

    static func remove<S: Sequence>(_ list: List, _ ids: S) -> List where S.Element == String {
        var list = list
        for id in ids { list[id] = nil }
        return list
    }

    /// Drops what has waited longer than `maxAge`.
    static func expire(_ list: List, now: Int) -> List {
        list.filter { now - $0.value.since <= maxAge }
    }

    static func encode(_ list: List) -> Data? {
        try? JSONEncoder().encode(list)
    }

    /// Anything unreadable reads as nothing pending.
    static func decode(_ data: Data?) -> List {
        guard let data, let list = try? JSONDecoder().decode(List.self, from: data) else { return [:] }
        return list
    }
}
