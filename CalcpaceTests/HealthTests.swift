@testable import Calcpace
import XCTest

final class WorkoutMapperTests: XCTestCase {
    private let uuid = UUID(uuidString: "0A1B2C3D-4E5F-6071-8293-A4B5C6D7E8F9")!
    private let start = Date(timeIntervalSince1970: 1_793_000_000) // 2026-10-26T…Z

    private func facts(
        kind: WorkoutFacts.Kind = .running, indoor: Bool = false, minutes: Double = 25, duration: TimeInterval? = nil,
        distance: Double? = 5000, elevation: Double? = nil, timeZone: String? = nil, device: String? = nil,
        hrAvg: Double? = nil, hrMax: Double? = nil, route: [HealthRoute.Point]? = nil
    ) -> WorkoutFacts {
        WorkoutFacts(
            id: uuid, kind: kind, indoor: indoor, start: start, end: start.addingTimeInterval(minutes * 60),
            duration: duration ?? minutes * 60, distanceM: distance, elevationGainM: elevation, timeZone: timeZone,
            origin: "com.strava.stravaride", device: device, hrAvg: hrAvg, hrMax: hrMax, route: route
        )
    }

    private func points(_ seconds: Int) -> [HealthRoute.Point] {
        (0 ... seconds).map { HealthRoute.Point(time: start.addingTimeInterval(Double($0)), lat: -5.8, lon: -35.2) }
    }

    func testARunInTheServersFormat() throws {
        let session = try XCTUnwrap(WorkoutMapper.wire(facts(device: "  Apple Watch ", hrAvg: 154.6, hrMax: 171.2)))
        XCTAssertEqual(session.id, "0a1b2c3d-4e5f-6071-8293-a4b5c6d7e8f9")
        XCTAssertEqual(session.type, "running")
        XCTAssertEqual(session.start, WorkoutMapper.timestamp(start))
        XCTAssertTrue(session.start.hasSuffix("Z"))
        XCTAssertFalse(session.start.contains("."), "Time.iso8601 on the server; no fraction needed")
        XCTAssertEqual(session.origin, "com.strava.stravaride")
        XCTAssertEqual(session.device, "Apple Watch")
        XCTAssertEqual(session.distanceM, 5000)
        XCTAssertEqual(session.durationS, 1500)
        XCTAssertEqual(session.hrAvg, 155)
        XCTAssertEqual(session.hrMax, 171)
        XCTAssertNil(session.zoneOffset)
        XCTAssertNil(session.elevationGainM)
        XCTAssertNil(session.route)
    }

    func testTheRouteThinned() throws {
        let session = try XCTUnwrap(WorkoutMapper.wire(facts(route: points(60))))
        let route = try XCTUnwrap(session.route)
        XCTAssertEqual(route.count, 13)
        XCTAssertEqual(route.first, WirePoint(time: 1_793_000_000, lat: -5.8, lon: -35.2))
        XCTAssertEqual(route.last?.time, 1_793_000_060)
    }

    func testNoRouteIndoorsOrOfASinglePoint() {
        XCTAssertNil(WorkoutMapper.wire(facts(indoor: true, route: points(60)))?.route)
        XCTAssertNil(WorkoutMapper.wire(facts(route: points(0)))?.route)
        XCTAssertNil(WorkoutMapper.wire(facts(route: []))?.route)
    }

    func testWhatASyncDoesWithEachWorkout() throws {
        guard case let .ready(session, awaitsRoute) = WorkoutMapper.judge(facts(route: points(60))) else { return XCTFail() }
        XCTAssertNotNil(session.route)
        XCTAssertFalse(awaitsRoute)

        // Outdoors without a route: sent, and read again for it.
        XCTAssertEqual(WorkoutMapper.judge(facts()), .ready(try XCTUnwrap(WorkoutMapper.wire(facts())), awaitsRoute: true))
        XCTAssertEqual(WorkoutMapper.judge(facts(kind: .walking)), .ready(try XCTUnwrap(WorkoutMapper.wire(facts(kind: .walking))), awaitsRoute: true))
        // A route there but unusable never changes: not waited for.
        guard case let .ready(single, false) = WorkoutMapper.judge(facts(route: points(0))) else { return XCTFail() }
        XCTAssertNil(single.route)
        // Indoors: no route to wait for.
        guard case .ready(_, false) = WorkoutMapper.judge(facts(indoor: true)) else { return XCTFail() }

        XCTAssertEqual(WorkoutMapper.judge(facts(distance: nil)), .awaitsDistance)
        XCTAssertEqual(WorkoutMapper.judge(facts(distance: 0)), .awaitsDistance)
        XCTAssertEqual(WorkoutMapper.judge(facts(kind: .other)), .left)
        XCTAssertEqual(WorkoutMapper.judge(facts(kind: .other, distance: nil)), .left)
        XCTAssertEqual(WorkoutMapper.judge(facts(minutes: 0, distance: nil)), .left)
        XCTAssertEqual(WorkoutMapper.judge(facts(duration: 0.2)), .left)
    }

    func testTreadmillAndWalk() {
        XCTAssertEqual(WorkoutMapper.wire(facts(indoor: true))?.type, "running_treadmill")
        XCTAssertEqual(WorkoutMapper.wire(facts(kind: .walking))?.type, "walking")
        XCTAssertEqual(WorkoutMapper.wire(facts(kind: .walking, indoor: true))?.type, "walking")
    }

    func testLeavesOutWhatIsNoRunOrHasNoDistance() {
        XCTAssertNil(WorkoutMapper.wire(facts(kind: .other)))
        XCTAssertNil(WorkoutMapper.wire(facts(distance: nil)))
        XCTAssertNil(WorkoutMapper.wire(facts(distance: 0)))
        XCTAssertNil(WorkoutMapper.wire(facts(distance: .infinity)))
        XCTAssertNil(WorkoutMapper.wire(facts(duration: 0.2)))
        XCTAssertNil(WorkoutMapper.wire(facts(minutes: 0)))
    }

    func testThePausesStayOut() {
        XCTAssertEqual(WorkoutMapper.wire(facts(minutes: 30, duration: 1620))?.durationS, 1620)
    }

    func testTheWorkoutsTimeZoneAtItsStart() {
        XCTAssertEqual(WorkoutMapper.wire(facts(timeZone: "America/Sao_Paulo"))?.zoneOffset, -10800)
        XCTAssertEqual(WorkoutMapper.wire(facts(timeZone: "Asia/Kolkata"))?.zoneOffset, 19800)
        XCTAssertNil(WorkoutMapper.wire(facts(timeZone: "Nowhere/Atlantis"))?.zoneOffset)
    }

    func testOddFiguresAreLeftOut() {
        let session = WorkoutMapper.wire(facts(elevation: -3, device: "   ", hrAvg: 0, hrMax: .nan))
        XCTAssertNil(session?.elevationGainM)
        XCTAssertNil(session?.device)
        XCTAssertNil(session?.hrAvg)
        XCTAssertNil(session?.hrMax)
        XCTAssertEqual(WorkoutMapper.wire(facts(elevation: 42.5))?.elevationGainM, 42.5)
        XCTAssertEqual(WorkoutMapper.wire(facts(device: String(repeating: "x", count: 150)))?.device?.count, 100)
    }

    func testDistanceSavedApartCountsWhereItsMiddleFalls() {
        let start = Date(timeIntervalSince1970: 1_793_000_000)
        let end = start.addingTimeInterval(1800)
        func sample(_ from: Double, _ to: Double, _ meters: Double) -> WorkoutMapper.DistanceSample {
            WorkoutMapper.DistanceSample(start: start.addingTimeInterval(from), end: start.addingTimeInterval(to), meters: meters)
        }
        // One sample over exactly the workout's time.
        XCTAssertEqual(WorkoutMapper.meters([sample(0, 1800, 4000)], from: start, to: end), 4000)
        // At the seams with the workouts before and after: once, in the one
        // holding its middle.
        XCTAssertEqual(WorkoutMapper.meters([sample(-0.4, 0.6, 3), sample(1799.6, 1800.4, 3), sample(1799.4, 1800.8, 3)], from: start, to: end), 6)
        XCTAssertEqual(WorkoutMapper.meters([sample(-0.8, 0.2, 3), sample(1800, 1800.8, 3)], from: start, to: end), nil)
        XCTAssertEqual(WorkoutMapper.meters([sample(0, 600, 1000), sample(600, 1200, 1000), sample(1200, 1800, 1000)], from: start, to: end), 3000)
        XCTAssertNil(WorkoutMapper.meters([], from: start, to: end))
        XCTAssertNil(WorkoutMapper.meters([sample(0, 1800, 0), sample(0, 1800, .nan), sample(10, 5, 100)], from: start, to: end))
        XCTAssertNil(WorkoutMapper.meters([sample(0, 1800, 4000)], from: end, to: start))
    }
}

final class HealthRouteTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_793_000_000)

    private func point(_ second: Double, lat: Double = -5.8, lon: Double = -35.2) -> HealthRoute.Point {
        HealthRoute.Point(time: start.addingTimeInterval(second), lat: lat, lon: lon)
    }

    func testAPointEveryFiveSecondsTheFirstAndLastAlways() {
        let thinned = HealthRoute.thin((0 ... 12).map { point(Double($0)) })
        XCTAssertEqual(thinned.map { $0.time.timeIntervalSince(start) }, [0, 5, 10, 12])
    }

    func testOutOfOrderAndOffTheMap() {
        let thinned = HealthRoute.thin([point(10), point(0), point(5, lat: 91), point(6, lon: -181), point(20)])
        XCTAssertEqual(thinned.map { $0.time.timeIntervalSince(start) }, [0, 10, 20])
    }

    func testClippedToTheWorkoutWithASlackOfAMinute() {
        let points = [point(-61), point(-60), point(0), point(600), point(660), point(661)]
        let clipped = HealthRoute.clip(points, from: start, to: start.addingTimeInterval(600))
        XCTAssertEqual(clipped.map { $0.time.timeIntervalSince(start) }, [-60, 0, 600, 660])
    }

    func testTooLongOrTooShortGoesNotAtAll() {
        XCTAssertEqual(HealthRoute.thin([]), [])
        XCTAssertEqual(HealthRoute.thin([point(0)]), [])
        XCTAssertEqual(HealthRoute.thin([point(0), point(1)]).count, 2, "the last always")
        let long = (0 ... HealthRoute.maxPoints).map { point(Double($0) * 5) }
        XCTAssertEqual(HealthRoute.thin(long), [])
        XCTAssertEqual(HealthRoute.thin(Array(long.dropLast())).count, HealthRoute.maxPoints)
    }

    func testTheJsonTheServerReads() throws {
        var session = WireSession(id: "a", type: "running", start: "s", end: "e", origin: "o", distanceM: 1, durationS: 1)
        session.route = HealthRoute.wire([point(0.9, lat: -5.81, lon: -35.2), point(5)])
        let data = try JSONEncoder().encode(session)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let route = try XCTUnwrap(json["route"] as? [[Any]])
        XCTAssertEqual(route.count, 2)
        XCTAssertEqual(route[0][0] as? Int, 1_793_000_000, "whole seconds")
        XCTAssertEqual(route[0][1] as? Double, -5.81)
        XCTAssertEqual(route[0][2] as? Double, -35.2)
        XCTAssertEqual(route[1][0] as? Int, 1_793_000_005)
    }
}

final class PendingWorkoutsTests: XCTestCase {
    func testKeepsTheFirstSightingWhateverTheReason() {
        var list = PendingWorkouts.mark([:], "a", .distance, now: 100)
        list = PendingWorkouts.mark(list, "a", .route, now: 200)
        XCTAssertEqual(list["a"], PendingWorkouts.Entry(since: 100, reason: .route))
    }

    func testRemoveAndExpire() {
        var list = PendingWorkouts.mark([:], "a", .route, now: 0)
        list = PendingWorkouts.mark(list, "b", .distance, now: 10)
        list = PendingWorkouts.mark(list, "c", .distance, now: 20)
        XCTAssertEqual(Set(PendingWorkouts.remove(list, ["b", "x"]).keys), ["a", "c"])
        XCTAssertEqual(Set(PendingWorkouts.expire(list, now: PendingWorkouts.maxAge + 10).keys), ["b", "c"])
    }

    func testKeepsTheNewest() {
        var list: PendingWorkouts.List = [:]
        for index in 0 ... PendingWorkouts.maxEntries {
            list = PendingWorkouts.mark(list, "w\(index)", .route, now: index)
        }
        XCTAssertEqual(list.count, PendingWorkouts.maxEntries)
        XCTAssertNil(list["w0"])
        XCTAssertNotNil(list["w\(PendingWorkouts.maxEntries)"])
    }

    func testAWorkoutNeverSentOutlastsOnesWaitingForAMap() {
        var list = PendingWorkouts.mark([:], "old", .distance, now: 0)
        for index in 0 ..< PendingWorkouts.maxEntries {
            list = PendingWorkouts.mark(list, "r\(index)", .route, now: 50)
        }
        XCTAssertEqual(list.count, PendingWorkouts.maxEntries)
        XCTAssertNotNil(list["old"])
    }

    private let session = WireSession(id: "a", type: "running", start: "s", end: "e", origin: "o", distanceM: 1, durationS: 1)

    func testWhatASyncDoesNext() {
        // New, outdoors, no route yet: sent, then waited for.
        XCTAssertTrue(PendingWorkouts.next(.ready(session, awaitsRoute: true), waiting: nil, changed: true) == (session, .route))
        // Waiting for its distance, which came: sent, then its route waited for.
        XCTAssertTrue(PendingWorkouts.next(.ready(session, awaitsRoute: true), waiting: .distance, changed: false) == (session, .route))
        // Sent, still no route: not sent again.
        XCTAssertTrue(PendingWorkouts.next(.ready(session, awaitsRoute: true), waiting: .route, changed: false) == (nil, .route))
        // Sent, then written again in Apple Health: sent again.
        XCTAssertTrue(PendingWorkouts.next(.ready(session, awaitsRoute: true), waiting: .route, changed: true) == (session, .route))
        // Its route came: sent with it, off the list.
        XCTAssertTrue(PendingWorkouts.next(.ready(session, awaitsRoute: false), waiting: .route, changed: false) == (session, nil))
        XCTAssertTrue(PendingWorkouts.next(.awaitsDistance, waiting: nil, changed: true) == (nil, .distance))
        // Sent, its distance unreadable this time: still waiting for its route.
        XCTAssertTrue(PendingWorkouts.next(.awaitsDistance, waiting: .route, changed: false) == (nil, .route))
        XCTAssertTrue(PendingWorkouts.next(.left, waiting: .route, changed: false) == (nil, nil))
    }

    func testRoundTripAndGarbage() {
        let list = PendingWorkouts.mark([:], "a", .route, now: 5)
        XCTAssertEqual(PendingWorkouts.decode(PendingWorkouts.encode(list)), list)
        XCTAssertEqual(PendingWorkouts.decode(nil), [:])
        XCTAssertEqual(PendingWorkouts.decode(Data("nope".utf8)), [:])
        XCTAssertEqual(PendingWorkouts.decode(Data(#"{"a":{"since":1,"reason":"steps"}}"#.utf8)), [:])
    }
}

final class HealthPayloadTests: XCTestCase {
    private func session(_ id: String, distance: Double = 1000, points: Int = 0) -> WireSession {
        var session = WireSession(id: id, type: "running", start: "2026-10-30T10:00:00Z", end: "2026-10-30T10:10:00Z",
                                  origin: "app.calcpace.ios", distanceM: distance, durationS: 600)
        if points > 0 {
            session.route = (0 ..< points).map { WirePoint(time: 1_793_000_000 + $0, lat: 0, lon: 0) }
        }
        return session
    }

    func testRoutesWithinTheServersBudget() {
        let max = HealthRoute.maxPoints
        let sessions = [session("a", points: max), session("b", points: max), session("c", points: 1), session("d")]
        let batches = HealthPayload.batches(sessions: sessions, deleted: ["x"], initial: false)
        XCTAssertEqual(batches.map { $0.sessions.map(\.id) }, [["a", "b"], ["c", "d"]])
        XCTAssertEqual(batches.map(\.deleted), [["x"], []])
        XCTAssertTrue(batches.allSatisfy { $0.sessions.reduce(0) { $0 + ($1.route?.count ?? 0) } <= HealthRoute.maxPointsPerUpload })
    }

    func testTheJsonTheServerReads() throws {
        var full = session("a")
        full.zoneOffset = -10800
        full.hrAvg = 150
        let data = try XCTUnwrap(HealthPayload.encode(Upload(initial: true, sessions: [full, session("b")], deleted: ["c"])))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["initial"] as? Bool, true)
        XCTAssertEqual(json["deleted"] as? [String], ["c"])
        let sessions = try XCTUnwrap(json["sessions"] as? [[String: Any]])
        XCTAssertEqual(Set(sessions[0].keys), ["id", "type", "start", "end", "zone_offset", "origin", "distance_m", "duration_s", "hr_avg"])
        XCTAssertEqual(sessions[0]["zone_offset"] as? Int, -10800)
        XCTAssertEqual(Set(sessions[1].keys), ["id", "type", "start", "end", "origin", "distance_m", "duration_s"], "nil fields stay out")
    }

    func testBatchesWithinTheServersLimits() {
        let sessions = (0 ..< 120).map { session("s\($0)") }
        let deleted = (0 ..< 250).map { "d\($0)" }
        let batches = HealthPayload.batches(sessions: sessions, deleted: deleted, initial: false)
        XCTAssertEqual(batches.map(\.sessions.count), [50, 50, 20])
        XCTAssertEqual(batches.map(\.deleted.count), [200, 50, 0])
        XCTAssertTrue(batches.allSatisfy { !$0.initial })
    }

    func testNothingToSayNoRequest() {
        XCTAssertEqual(HealthPayload.batches(sessions: [], deleted: [], initial: true), [])
    }

    func testTheSameWorkoutTwiceSendsTheLastWord() {
        let batches = HealthPayload.batches(sessions: [session("a", distance: 1), session("b"), session("a", distance: 2)], deleted: ["x", "x"], initial: false)
        XCTAssertEqual(batches.count, 1)
        XCTAssertEqual(batches[0].sessions.map(\.id), ["b", "a"])
        XCTAssertEqual(batches[0].sessions.last?.distanceM, 2)
        XCTAssertEqual(batches[0].deleted, ["x"])
    }

    func testLinkToken() {
        XCTAssertTrue(HealthPayload.isLinkToken(String(repeating: "aZ0_-", count: 8) + "abc"))
        XCTAssertFalse(HealthPayload.isLinkToken(String(repeating: "a", count: 42)))
        XCTAssertFalse(HealthPayload.isLinkToken(String(repeating: "a", count: 44)))
        XCTAssertFalse(HealthPayload.isLinkToken(String(repeating: "a", count: 42) + "="))
        XCTAssertFalse(HealthPayload.isLinkToken(String(repeating: "a", count: 43) + "\n"))
        XCTAssertFalse(HealthPayload.isLinkToken(nil))
    }

    func testLinkRequest() {
        let request = HealthPayload.linkRequest(#"{"token": "t", "grant": "g"}"#)
        XCTAssertEqual(request?.token, "t")
        XCTAssertEqual(request?.grant, "g")
        XCTAssertNil(HealthPayload.linkRequest(#"{"token": 12}"#))
        XCTAssertNil(HealthPayload.linkRequest("nope"))
        XCTAssertNil(HealthPayload.linkRequest("{}")?.token)
    }
}

final class SyncPlanTests: XCTestCase {
    func testWhatEachAnswerMeans() {
        XCTAssertEqual(SyncPlan.after(200), .advance)
        XCTAssertEqual(SyncPlan.after(204), .advance)
        XCTAssertEqual(SyncPlan.after(401), .unlink)
        for status in [400, 409, 413, 422] {
            XCTAssertEqual(SyncPlan.after(status), .advance, "\(status)")
        }
        for status in [SyncPlan.noAnswer, 302, 403, 429, 500, 503] {
            XCTAssertEqual(SyncPlan.after(status), .retry, "\(status)")
        }
    }

    func testTheFirstAnswerThatIsNotAnAdvanceDecides() {
        XCTAssertEqual(SyncPlan.overall([]), .advance)
        XCTAssertEqual(SyncPlan.overall([.advance, .advance]), .advance)
        XCTAssertEqual(SyncPlan.overall([.advance, .retry, .unlink]), .retry)
        XCTAssertEqual(SyncPlan.overall([.unlink]), .unlink)
    }

    func testTheInitialReadIsThirtyDays() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(SyncPlan.initialStart(now: now), now.addingTimeInterval(-30 * 86400))
    }
}

final class LinkGateTests: XCTestCase {
    private var now = Date(timeIntervalSince1970: 1_800_000_000)
    private var counter: UInt8 = 0

    private func gate() -> LinkGate {
        LinkGate(clock: { [unowned self] in self.now }, random: { [unowned self] count in
            self.counter &+= 1
            return [UInt8](repeating: self.counter, count: count)
        })
    }

    func testTheGrantOfTheLastEnableOnce() {
        let gate = gate()
        let grant = gate.open()
        XCTAssertEqual(grant.count, 43)
        XCTAssertTrue(gate.consume(grant))
        XCTAssertFalse(gate.consume(grant), "used")
    }

    func testAWrongGrantSpendsIt() {
        let gate = gate()
        let grant = gate.open()
        XCTAssertFalse(gate.consume("guess"))
        XCTAssertFalse(gate.consume(grant))
        XCTAssertFalse(gate.consume(nil))
    }

    func testNothingOpenNothingTaken() {
        XCTAssertFalse(gate().consume("anything"))
    }

    func testADoubleTapKeepsTheFirstGrant() {
        let gate = gate()
        let first = gate.open()
        XCTAssertEqual(gate.open(), first)
        XCTAssertTrue(gate.consume(first))
        XCTAssertNotEqual(gate.open(), first, "a new one after a link")
    }

    func testExpires() {
        let gate = gate()
        let grant = gate.open()
        now = now.addingTimeInterval(LinkGate.window + 1)
        XCTAssertFalse(gate.consume(grant))
    }

    func testRealRandomGrantsDiffer() {
        let a = LinkGate().open()
        let b = LinkGate().open()
        XCTAssertNotEqual(a, b)
        XCTAssertNil(a.range(of: "[^A-Za-z0-9_-]", options: .regularExpression))
    }
}

final class HealthPagesTests: XCTestCase {
    private let root = URL(string: "https://calcpace.app")!

    func testTheHomePageAndAppleHealthSettings() {
        for path in ["", "/", "/pt-BR", "/pt-BR/", "/settings/apple-health", "/zh-TW/settings/apple-health", "/?from=app", "/settings/apple-health#top"] {
            XCTAssertTrue(HealthPages.isAllowed(URL(string: "https://calcpace.app" + path), rootURL: root), path)
        }
    }

    func testNowhereElse() {
        for url in [
            "https://calcpace.app/activities", "https://calcpace.app/settings", "https://calcpace.app/settings/health-connect",
            "https://calcpace.app/xx", "https://calcpace.app//settings/apple-health", "https://calcpace.app/settings/apple-health/x",
            "https://calcpace.app.evil.com/", "https://evil.com/?https://calcpace.app/", "http://calcpace.app/"
        ] {
            XCTAssertFalse(HealthPages.isAllowed(URL(string: url), rootURL: root), url)
        }
        XCTAssertFalse(HealthPages.isAllowed(nil, rootURL: root))
    }
}

final class HealthLinkStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var store: HealthLinkStore!

    override func setUp() {
        defaults = UserDefaults(suiteName: "HealthLinkStoreTests")!
        defaults.removePersistentDomain(forName: "HealthLinkStoreTests")
        store = HealthLinkStore(service: "app.calcpace.ios.tests.apple-health", defaults: defaults)
        store.clear()
    }

    override func tearDown() {
        store.clear()
        defaults.removePersistentDomain(forName: "HealthLinkStoreTests")
    }

    func testKeepsTheTokenUntilCleared() {
        XCTAssertNil(store.token)
        XCTAssertTrue(store.link(token: "first"))
        XCTAssertEqual(store.token, "first")
        XCTAssertTrue(store.link(token: "second"))
        XCTAssertEqual(store.token, "second")
        store.clear()
        XCTAssertNil(store.token)
    }

    func testThePendingListGoesWithTheAnchorOfItsLink() {
        let list = PendingWorkouts.mark([:], "a", .route, now: 1)
        store.link(token: "first")
        store.save(anchor: nil, pending: list, for: "other")
        XCTAssertEqual(store.pending, [:], "not this link's")
        store.save(anchor: nil, pending: list, for: "first")
        XCTAssertEqual(store.pending, list)
        store.link(token: "second")
        XCTAssertEqual(store.pending, [:], "a new link starts afresh")
        store.save(anchor: nil, pending: list, for: "second")
        store.clear()
        XCTAssertEqual(store.pending, [:])
    }

    func testAFreshInstallStartsUnlinked() {
        store.link(token: "left by the last install")
        defaults.removeObject(forKey: "appleHealth.installed")
        store.forgetPreviousInstall()
        XCTAssertNil(store.token)

        store.link(token: "this install")
        store.forgetPreviousInstall()
        XCTAssertEqual(store.token, "this install", "only once")
    }
}
