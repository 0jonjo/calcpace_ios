@testable import Calcpace
import XCTest

final class WorkoutMapperTests: XCTestCase {
    private let uuid = UUID(uuidString: "0A1B2C3D-4E5F-6071-8293-A4B5C6D7E8F9")!
    private let start = Date(timeIntervalSince1970: 1_793_000_000) // 2026-10-26T…Z

    private func facts(
        kind: WorkoutFacts.Kind = .running, indoor: Bool = false, minutes: Double = 25, duration: TimeInterval? = nil,
        distance: Double? = 5000, elevation: Double? = nil, timeZone: String? = nil, device: String? = nil,
        hrAvg: Double? = nil, hrMax: Double? = nil
    ) -> WorkoutFacts {
        WorkoutFacts(
            id: uuid, kind: kind, indoor: indoor, start: start, end: start.addingTimeInterval(minutes * 60),
            duration: duration ?? minutes * 60, distanceM: distance, elevationGainM: elevation, timeZone: timeZone,
            origin: "com.strava.stravaride", device: device, hrAvg: hrAvg, hrMax: hrMax
        )
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
}

final class HealthPayloadTests: XCTestCase {
    private func session(_ id: String, distance: Double = 1000) -> WireSession {
        WireSession(id: id, type: "running", start: "2026-10-30T10:00:00Z", end: "2026-10-30T10:10:00Z",
                    origin: "app.calcpace.ios", distanceM: distance, durationS: 600)
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
