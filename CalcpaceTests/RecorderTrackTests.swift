@testable import Calcpace
import XCTest

// The Android app's cases (TrackTest.kt), on the same rules: a run measures
// the same on both phones.
final class RecorderTrackTests: XCTestCase {
    // Northward along a meridian: 0.00001° of latitude ≈ 1.112 m.
    private let lat0 = -5.84
    private let lon0 = -35.2
    private let t0: Int64 = 1_760_000_000_000

    private func point(_ seconds: Int, _ metersNorth: Double, accuracy: Double = 5) -> RunFix {
        RunFix(time: t0 + Int64(seconds) * 1000, lat: lat0 + metersNorth / 111_195.0, lon: lon0, altitude: 30, accuracy: accuracy)
    }

    private func fix(_ seconds: Int, _ metersNorth: Double, accuracy: Double = 5) -> RunEvent {
        .fix(point(seconds, metersNorth, accuracy: accuracy))
    }

    /// A steady run at `speed` m/s, one fix a second, from `from` seconds.
    private func run(_ from: Int, _ seconds: Int, speed: Double = 3.0, startAt: Double = 0.0) -> [RunEvent] {
        (0 ... seconds).map { fix(from + $0, startAt + Double($0) * speed) }
    }

    private func start(_ time: Int64) -> RunEvent {
        .start(time: time, recordingId: nil, utcOffsetSeconds: nil)
    }

    func testASteadyRunAddsUpItsDistanceAndTime() throws {
        let track = Track([start(t0)] + run(0, 600) + [.stop(time: t0 + 600_000)])

        XCTAssertEqual(track.distanceMeters, 1800, accuracy: 6)
        XCTAssertEqual(track.movingMillis(t0 + 999_999), 600_000)
        XCTAssertEqual(try XCTUnwrap(track.averagePace(t0 + 600_000)), 333.3, accuracy: 1.5)
        XCTAssertTrue(track.isStopped)
        XCTAssertEqual(track.segments.count, 1)
        XCTAssertEqual(track.segments[0].count, 601)
    }

    func testStandingStillWithADriftingGpsAddsNothing() {
        let drift = (0 ... 120).map { fix($0, $0 % 2 == 0 ? 0 : 3, accuracy: 8) }
        let track = Track([start(t0)] + drift)

        XCTAssertEqual(track.distanceMeters, 0, accuracy: 0.001)
        XCTAssertNil(track.averagePace(t0 + 120_000))
    }

    // What a GPS around someone standing still really does: wanders 6–10 m,
    // past minStep. Each wander that far counts, so a minute at a light adds
    // some metres; the filter keeps it to a fraction of the wander.
    func testStandingStillWithAWanderingGpsAddsLittle() {
        let wander = (0 ... 60).map { point($0, [0.0, 6.0, 2.0, 9.0, 4.0, 10.0][$0 % 6], accuracy: 12) }
        let track = Track([start(t0)] + wander.map(RunEvent.fix))

        let wanderedTotal = zip(wander, wander.dropFirst()).map { Track.distance($0, $1) }.reduce(0, +)
        XCTAssertGreaterThan(track.distanceMeters, 0)
        XCTAssertLessThan(track.distanceMeters, wanderedTotal * 0.6, "got \(track.distanceMeters) of \(wanderedTotal)")
    }

    func testImpreciseFixesAreDropped() {
        let events = [start(t0), fix(0, 0, accuracy: 60), fix(1, 500, accuracy: 40)] + run(2, 10, startAt: 0)
        let track = Track(events)

        XCTAssertEqual(track.dropped, 2)
        XCTAssertEqual(track.distanceMeters, 30, accuracy: 1)
    }

    func testASingleJumpIsDroppedAndTheRunGoesOn() {
        let events = [start(t0)] + run(0, 10) + [fix(11, 400)] + run(12, 10, startAt: 36)
        let track = Track(events)

        XCTAssertEqual(track.dropped, 1)
        // 0 → 30 m, then 36 → 66 m: the 400 m spike is not in it.
        XCTAssertEqual(track.distanceMeters, 66, accuracy: 2)
    }

    // The fix the track was counting from was the wrong one: after a few
    // "jumps" in a row it starts again from where the GPS now is, without
    // adding the jump itself.
    func testARunOfJumpsMovesTheTrackWithoutCountingTheJump() {
        let events = [start(t0)] + run(0, 5) + (6 ... 20).map { fix($0, 2000 + Double($0 - 6) * 3) }
        let track = Track(events)

        XCTAssertEqual(track.dropped, Track.maxJumps - 1)
        XCTAssertLessThan(track.distanceMeters, 15 + 40)
    }

    // The restart after a run of jumps (a tunnel) adds nothing for the gap:
    // what the GPS got wrong is not run.
    func testTheStretchAcrossARestartIsNotCounted() {
        let events = [start(t0)] + run(0, 10) +
            // A tunnel: fixes 600 m off for 5 s, then back on the line at 45 m.
            (11 ... 15).map { fix($0, 600 + Double($0)) } + run(16, 10, startAt: 45)
        let track = Track(events)

        // 0 → 30 m, then from the restart (~611 m) on: 30 m along the
        // offset line… and back: the jump back is a restart of its own.
        XCTAssertLessThan(track.distanceMeters, 30 + 30 + 15)
    }

    func testTheCurrentPaceIsTheLastHalfMinute() throws {
        // 2 min at 3 m/s, then 2 min at 4 m/s.
        let track = Track([start(t0)] + run(0, 120) + run(121, 120, speed: 4, startAt: 363))

        XCTAssertEqual(try XCTUnwrap(track.currentPace(t0 + 241_000)), 250, accuracy: 10)
        // The average still holds the slower start.
        XCTAssertGreaterThan(try XCTUnwrap(track.averagePace(t0 + 241_000)), 280)
    }

    func testNoCurrentPaceWhenStoppedPausedOrJustStarted() {
        let track = Track([start(t0)] + run(0, 60))
        XCTAssertNotNil(track.currentPace(t0 + 60_000))
        // Standing at a light: nothing counted for 15 s.
        XCTAssertNil(track.currentPace(t0 + 60_000 + Track.paceStale + 1))

        track.add(.pause(time: t0 + 61_000))
        XCTAssertNil(track.currentPace(t0 + 61_000))
        XCTAssertEqual(track.pausedAt, t0 + 61_000)

        // Resumed: the window starts again, too little to say yet.
        track.add(.resume(time: t0 + 90_000))
        XCTAssertNil(track.pausedAt)
        track.add(fix(90, 500))
        track.add(fix(91, 503))
        XCTAssertNil(track.currentPace(t0 + 91_000))
    }

    func testTheStartCarriesTheRunsIdAndOffset() {
        let track = Track([.start(time: t0, recordingId: "3f2504e0-4f89-41d3-9a0c-0305e82c3301", utcOffsetSeconds: -10_800)])
        XCTAssertEqual(track.recordingId, "3f2504e0-4f89-41d3-9a0c-0305e82c3301")
        XCTAssertEqual(track.utcOffsetSeconds, -10_800)
        XCTAssertEqual(track.runningSince, t0)
    }

    func testPausesLeaveTheClockAndTheDistanceAlone() {
        let events = [start(t0)] + run(0, 100) +
            [.pause(time: t0 + 100_000), fix(150, 600)] + // the GPS still reports while paused: ignored
            [.resume(time: t0 + 200_000)] + run(200, 100, startAt: 900) +
            [.stop(time: t0 + 300_000)]
        let track = Track(events)

        XCTAssertEqual(track.movingMillis(t0 + 400_000), 200_000)
        // Nothing counted across the pause, even though the runner moved.
        XCTAssertEqual(track.distanceMeters, 600, accuracy: 6)
        XCTAssertEqual(track.segments.count, 2)
    }

    func testTheClockRunsUntilNowWhileRunningAndStopsWhilePaused() {
        let track = Track([start(t0)])
        XCTAssertTrue(track.isRunning)
        XCTAssertEqual(track.movingMillis(t0 + 42_000), 42_000)

        track.add(.pause(time: t0 + 50_000))
        XCTAssertTrue(track.isPaused)
        XCTAssertEqual(track.movingMillis(t0 + 90_000), 50_000)
    }

    func testTheLongestGapBetweenFixesIsKept() {
        let events = [start(t0)] + run(0, 10) + run(70, 10, startAt: 30)
        XCTAssertEqual(Track(events).longestGap, 60_000)
    }

    func testEventsOutOfPlaceChangeNothing() {
        let track = Track([
            fix(0, 0), .resume(time: t0), .pause(time: t0), .stop(time: t0),
            start(t0 + 1000), start(t0 + 5000), .resume(time: t0 + 6000),
        ])

        XCTAssertEqual(track.startedAt, t0 + 1000)
        XCTAssertTrue(track.isRunning)
        XCTAssertFalse(track.isStopped)
        XCTAssertEqual(track.fixes, 0)
    }

    func testDistanceMatchesAKnownLeg() {
        // Ponta Negra to Natal city centre, about 10.35 km as the crow flies.
        let a = RunFix(time: 0, lat: -5.8796, lon: -35.1729, altitude: nil, accuracy: 5)
        let b = RunFix(time: 0, lat: -5.7945, lon: -35.2110, altitude: nil, accuracy: 5)
        XCTAssertEqual(Track.distance(a, b), 10_350, accuracy: 150)
    }

    func testThePausesAreKeptFromPauseToResumeOrToTheStop() {
        let events = [start(t0)] + run(0, 100) + [.pause(time: t0 + 100_000), .pause(time: t0 + 110_000), .resume(time: t0 + 130_000)] +
            run(130, 70, startAt: 300) + [.pause(time: t0 + 200_000), .stop(time: t0 + 230_000)]

        let track = Track(events)

        XCTAssertEqual(track.pauses.map { [$0.0, $0.1] }, [[t0 + 100_000, t0 + 130_000], [t0 + 200_000, t0 + 230_000]])
    }

    func testARunStoppedWhileRunningEndsWithoutAPause() {
        let track = Track([start(t0)] + run(0, 60) + [.stop(time: t0 + 60_000)])

        XCTAssertTrue(track.pauses.isEmpty)
    }
}
