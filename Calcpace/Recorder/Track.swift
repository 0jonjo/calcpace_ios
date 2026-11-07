import Foundation

/// A run as the recorder sees it, rebuilt by feeding it the `RunEvent`s in
/// order: the same events live on screen and, after a kill, read back from
/// the `RunLog`. The Android app's Track.kt, rule for rule, so a run measures
/// the same on both phones. It decides which fixes count:
///
/// - a fix less precise than `maxAccuracy` is dropped (the first seconds of
///   a cold GPS, a run under trees);
/// - a fix that would mean running faster than `maxSpeed` from the last one
///   kept is a jump, and is dropped too. After `maxJumps` jumps in a row the
///   last kept fix is what was wrong, so the track starts again from the new
///   position without adding the jump to the distance;
/// - distance grows only once the runner is `minStep` away from the last
///   counted position, so a GPS drifting around someone standing still at a
///   traffic light adds nothing.
///
/// Moving time is the clock minus the pauses the runner made; a GPS that
/// lost its fix is still running time. Every kept fix goes in the route
/// (`segments`, one per stretch between pauses), counted or not.
final class Track {
    static let maxAccuracy = 25.0
    static let maxSpeed = 12.0
    static let maxJumps = 5
    static let minStep = 5.0
    static let paceWindow: Int64 = 30_000
    static let paceStale: Int64 = 15_000
    static let paceMinMeters = 20.0
    private static let earthRadius = 6_371_008.8

    private(set) var startedAt: Int64?
    private(set) var stoppedAt: Int64?
    private(set) var distanceMeters = 0.0
    private(set) var fixes = 0
    private(set) var dropped = 0
    /// The longest wait between two fixes while running.
    private(set) var longestGap: Int64 = 0
    private(set) var lastAccuracy: Double?
    /// When the last fix came, kept or not: how long the GPS has been quiet.
    private(set) var lastFixAt: Int64?
    /// When the current pause began, nil unless paused.
    private(set) var pausedAt: Int64?
    /// From the Start event (nil in an old Android log).
    private(set) var recordingId: String?
    private(set) var utcOffsetSeconds: Int?
    /// The pauses the runner made, (from, to): up to the Resume, or to the
    /// Stop for a run finished while paused.
    private(set) var pauses: [(Int64, Int64)] = []
    /// When the current stretch began (Start or the last Resume), nil unless running.
    private(set) var runningSince: Int64?

    private var stretches: [[RunFix]] = []
    var segments: [[RunFix]] { stretches.filter { !$0.isEmpty } }

    private var movingBefore: Int64 = 0
    private var counted: RunFix?
    private var lastKept: RunFix?
    private var lastFixTime: Int64?
    private var jumps = 0
    // Counted positions of the current stretch, (time, distance so far), for
    // the pace of the last `paceWindow`.
    private var recent: [(Int64, Double)] = []

    var isRunning: Bool { runningSince != nil }
    var isPaused: Bool { startedAt != nil && stoppedAt == nil && runningSince == nil }
    var isStopped: Bool { stoppedAt != nil }

    init() {}

    convenience init(_ events: [RunEvent]) {
        self.init()
        events.forEach(add)
    }

    func movingMillis(_ now: Int64) -> Int64 {
        movingBefore + (runningSince.map { max(now - $0, 0) } ?? 0)
    }

    /// Seconds per kilometre over the whole run, or nil before 50 m.
    func averagePace(_ now: Int64) -> Double? {
        distanceMeters < 50 ? nil : Double(movingMillis(now)) / 1000 / (distanceMeters / 1000)
    }

    /// Seconds per kilometre over the last `paceWindow` of counted distance,
    /// or nil: paused, too little distance in the window, or no position
    /// counted for `paceStale` (stopped at a light, no GPS).
    func currentPace(_ now: Int64) -> Double? {
        guard isRunning, let last = recent.last, now - last.0 <= Self.paceStale,
              let first = recent.first(where: { last.0 - $0.0 <= Self.paceWindow })
        else { return nil }
        let meters = last.1 - first.1
        let millis = last.0 - first.0
        guard meters >= Self.paceMinMeters, millis > 0 else { return nil }
        return Double(millis) / 1000 / (meters / 1000)
    }

    func add(_ event: RunEvent) {
        switch event {
        case let .start(time, id, offset):
            guard startedAt == nil else { return }
            startedAt = time
            recordingId = id
            utcOffsetSeconds = offset
            begin(time)
        case let .pause(time):
            if isRunning { end(time) }
        case let .resume(time):
            if isPaused { begin(time) }
        case let .stop(time):
            guard startedAt != nil, stoppedAt == nil else { return }
            if let pausedAt { pauses.append((pausedAt, time)) }
            if isRunning { end(time) }
            stoppedAt = time
            pausedAt = nil
        case let .fix(fix):
            if isRunning { add(fix) }
        }
    }

    static func distance(_ from: RunFix, _ to: RunFix) -> Double {
        let dLat = (to.lat - from.lat) * .pi / 180
        let dLon = (to.lon - from.lon) * .pi / 180
        let a = pow(sin(dLat / 2), 2) + cos(from.lat * .pi / 180) * cos(to.lat * .pi / 180) * pow(sin(dLon / 2), 2)
        return 2 * earthRadius * asin(sqrt(min(max(a, 0), 1)))
    }

    // MARK: Private

    private func begin(_ time: Int64) {
        if let pausedAt { pauses.append((pausedAt, time)) }
        runningSince = time
        pausedAt = nil
        recent.removeAll()
        stretches.append([])
        counted = nil
        lastKept = nil
        lastFixTime = nil
        jumps = 0
    }

    private func end(_ time: Int64) {
        movingBefore += max(time - (runningSince ?? time), 0)
        runningSince = nil
        pausedAt = time
    }

    private func add(_ fix: RunFix) {
        fixes += 1
        lastAccuracy = fix.accuracy
        if let lastFixTime { longestGap = max(longestGap, fix.time - lastFixTime) }
        lastFixTime = fix.time
        lastFixAt = fix.time
        guard fix.accuracy <= Self.maxAccuracy else {
            dropped += 1
            return
        }

        if let previous = lastKept, isJump(previous, fix) {
            jumps += 1
            if jumps < Self.maxJumps {
                dropped += 1
                return
            }
            counted = nil
            recent.removeAll()
        }
        jumps = 0
        lastKept = fix
        stretches[stretches.count - 1].append(fix)

        guard let from = counted else {
            counted = fix
            remember(fix.time)
            return
        }
        let step = Self.distance(from, fix)
        if step >= Self.minStep {
            distanceMeters += step
            counted = fix
            remember(fix.time)
        }
    }

    private func remember(_ time: Int64) {
        recent.append((time, distanceMeters))
        while recent.count > 1, time - recent[0].0 > Self.paceWindow { recent.removeFirst() }
    }

    private func isJump(_ from: RunFix, _ to: RunFix) -> Bool {
        let seconds = Double(to.time - from.time) / 1000
        if seconds <= 0 { return Self.distance(from, to) > Self.minStep }
        return Self.distance(from, to) / seconds > Self.maxSpeed
    }
}
