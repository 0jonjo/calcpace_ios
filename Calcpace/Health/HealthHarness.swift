#if DEBUG
import CoreLocation
import HealthKit
import UIKit

/// The UI tests' Apple Health run (`-healthHarness`, HealthTests): no site,
/// no account. It writes workouts to the simulator's Apple Health (the only
/// thing in this app that writes there, and only in a debug build), links
/// with a made-up token, and syncs against `FakeHealthServer`. The server's
/// side (Strava's copy left out, the checks) is calcpace_web's tests.
///
/// The steps run on their own once the screen is up; the HealthKit sheet is
/// the test's to answer. The label ends in "done …" or "error …".
enum HealthHarness {
    static var isOn: Bool { ProcessInfo.processInfo.arguments.contains("-healthHarness") }

    static let token = String(repeating: "T", count: 43)

    static let writeTypes: Set<HKSampleType> = [HealthReader.workoutType, HealthReader.distanceType, HealthReader.heartRateType, HealthReader.routeType]

    struct Seed {
        let activity: HKWorkoutActivityType
        let indoor: Bool
        let meters: Double?
        let hoursAgo: Double
        let minutes: Double
        let heartRates: [Double]
        var route = false
    }

    /// A run with its heart rate and route, a treadmill run, a walk whose
    /// route comes later, a ride that is no run (three sessions to send),
    /// and a run whose distance comes later.
    static let seeds = [
        Seed(activity: .running, indoor: false, meters: 5000, hoursAgo: 50, minutes: 25, heartRates: [150, 160], route: true),
        Seed(activity: .running, indoor: true, meters: 3000, hoursAgo: 30, minutes: 18, heartRates: []),
        Seed(activity: .walking, indoor: false, meters: 2000, hoursAgo: 20, minutes: 24, heartRates: []),
        Seed(activity: .cycling, indoor: false, meters: nil, hoursAgo: 10, minutes: 40, heartRates: []),
        Seed(activity: .running, indoor: false, meters: nil, hoursAgo: 5, minutes: 30, heartRates: [])
    ]
    static let lateRoute = 2
    static let lateDistance = 4
    static let lateMeters = 4000.0

    static func write(_ seed: Seed, to store: HKHealthStore) async throws -> HKWorkout {
        let end = Date().addingTimeInterval(-seed.hoursAgo * 3600)
        let start = end.addingTimeInterval(-seed.minutes * 60)

        let configuration = HKWorkoutConfiguration()
        configuration.activityType = seed.activity
        configuration.locationType = seed.indoor ? .indoor : .outdoor
        let builder = HKWorkoutBuilder(healthStore: store, configuration: configuration, device: .local())
        try await builder.beginCollection(at: start)

        var samples: [HKSample] = []
        if let meters = seed.meters {
            samples.append(HKQuantitySample(type: HealthReader.distanceType, quantity: HKQuantity(unit: .meter(), doubleValue: meters), start: start, end: end))
        }
        let bpm = HKUnit.count().unitDivided(by: .minute())
        for (index, rate) in seed.heartRates.enumerated() {
            let at = start.addingTimeInterval(Double(index + 1) * 60)
            samples.append(HKQuantitySample(type: HealthReader.heartRateType, quantity: HKQuantity(unit: bpm, doubleValue: rate), start: at, end: at))
        }
        if !samples.isEmpty { try await builder.addSamples(samples) }
        try await builder.addMetadata([
            HKMetadataKeyIndoorWorkout: seed.indoor,
            HKMetadataKeyTimeZone: "America/Sao_Paulo"
        ])
        try await builder.endCollection(at: end)
        guard let workout = try await builder.finishWorkout() else { throw HarnessError.notSaved }
        if seed.route { try await addRoute(to: workout, in: store) }
        return workout
    }

    /// A location every second of the workout, heading north from Natal: as
    /// an app does with HKWorkoutRouteBuilder, after saving the workout.
    static func addRoute(to workout: HKWorkout, in store: HKHealthStore) async throws {
        let seconds = Int(workout.endDate.timeIntervalSince(workout.startDate))
        let locations = (0 ... seconds).map { second in
            CLLocation(
                coordinate: CLLocationCoordinate2D(latitude: -5.8 + Double(second) * 0.00003, longitude: -35.2),
                altitude: 10, horizontalAccuracy: 5, verticalAccuracy: 5, course: 0, speed: 3,
                timestamp: workout.startDate.addingTimeInterval(Double(second))
            )
        }
        let builder = HKWorkoutRouteBuilder(healthStore: store, device: .local())
        try await builder.insertRouteData(locations)
        _ = try await builder.finishRoute(with: workout, metadata: nil)
    }

    /// Distance its app saves after the workout, over its time.
    static func addDistance(to workout: HKWorkout, in store: HKHealthStore) async throws {
        let sample = HKQuantitySample(type: HealthReader.distanceType, quantity: HKQuantity(unit: .meter(), doubleValue: lateMeters), start: workout.startDate, end: workout.endDate)
        try await store.save(sample)
    }

    enum HarnessError: Error {
        case notSaved
    }
}

/// Records what the app sends and answers with `status`. Lives in the app's
/// process, behind the uploader's own URLSession only.
final class FakeHealthServer: URLProtocol {
    struct Received {
        let authorization: String?
        let body: [String: Any]
    }

    private static let lock = NSLock()
    private static var _received: [Received] = []
    private static var _status = 200

    static var configuration: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FakeHealthServer.self]
        return configuration
    }

    static var received: [Received] {
        lock.lock()
        defer { lock.unlock() }
        return _received
    }

    static var status: Int {
        get { lock.lock(); defer { lock.unlock() }; return _status }
        set { lock.lock(); _status = newValue; lock.unlock() }
    }

    static var sessions: [[String: Any]] {
        received.flatMap { $0.body["sessions"] as? [[String: Any]] ?? [] }
    }

    static var deleted: [String] {
        received.flatMap { $0.body["deleted"] as? [String] ?? [] }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let data = request.httpBody ?? Self.read(request.httpBodyStream)
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        Self.lock.lock()
        Self._received.append(Received(authorization: request.value(forHTTPHeaderField: "Authorization"), body: body))
        let status = Self._status
        Self.lock.unlock()

        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"results":{}}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func read(_ stream: InputStream?) -> Data {
        guard let stream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

final class HealthHarnessViewController: UIViewController {
    private let label = UILabel()
    private var started = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .white
        label.numberOfLines = 0
        label.textAlignment = .center
        label.font = .preferredFont(forTextStyle: .body)
        label.accessibilityIdentifier = "harness.status"
        label.text = "starting"
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            label.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !started else { return }
        started = true
        Task { await run() }
    }

    private func show(_ text: String) {
        label.text = text
    }

    private func run() async {
        let store = HKHealthStore()
        let sync = HealthSync.shared
        await sync.use(uploader: HealthUploader(configuration: FakeHealthServer.configuration))
        await sync.forget()

        do {
            show("asking")
            // A freshly booted simulator's HealthKit may time the sheet out
            // before showing it: asked again, a few times.
            for attempt in 1 ... 3 {
                do {
                    try await store.requestAuthorization(toShare: HealthHarness.writeTypes, read: HealthReader.readTypes)
                    break
                } catch where attempt < 3 {
                    show("asking again")
                }
            }
            // A simulator the test ran on before: what it wrote goes first.
            for type in HealthHarness.writeTypes {
                _ = try? await store.deleteObjects(of: type, predicate: HKQuery.predicateForObjects(from: HKSource.default()))
            }
            show("writing")
            var workouts: [HKWorkout] = []
            for seed in HealthHarness.seeds {
                workouts.append(try await HealthHarness.write(seed, to: store))
            }

            // The link's first sync: the last 30 days.
            show("linking")
            guard await sync.link(token: HealthHarness.token) else { return show("error link refused") }
            _ = await sync.run()
            let sent = FakeHealthServer.sessions
            let types = sent.compactMap { $0["type"] as? String }.sorted()
            let run = sent.first { $0["type"] as? String == "running" }
            let route = run?["route"] as? [[Any]] ?? []
            let routeShape = route.allSatisfy { $0.count == 3 && $0[0] is Int && $0[1] is Double && $0[2] is Double }
            let firstInitial = FakeHealthServer.received.first?.body["initial"] as? Bool

            // What their apps save after the workouts: the walk's route, the
            // run's distance. The route's observer may sync first: whatever
            // reached the server since counts.
            show("saving later")
            let before = FakeHealthServer.sessions.count
            try await HealthHarness.addDistance(to: workouts[HealthHarness.lateDistance], in: store)
            try await HealthHarness.addRoute(to: workouts[HealthHarness.lateRoute], in: store)
            _ = await sync.run()
            let later = FakeHealthServer.sessions.dropFirst(before)
            let walkId = WorkoutMapper.id(workouts[HealthHarness.lateRoute].uuid)
            let runId = WorkoutMapper.id(workouts[HealthHarness.lateDistance].uuid)
            let lateRoute = (later.last { $0["id"] as? String == walkId }?["route"] as? [Any])?.count ?? 0
            let lateDistance = later.last { $0["id"] as? String == runId }?["distance_m"] as? Double ?? 0
            let laterIds = Set(later.compactMap { $0["id"] as? String })

            // Nothing new: nothing sent, the run still waiting for a route included.
            show("quiet")
            let settled = FakeHealthServer.sessions.count
            _ = await sync.run()
            let quiet = FakeHealthServer.sessions.count == settled

            // Deleted in Apple Health: the next sync says so.
            show("deleting")
            try await store.delete(workouts[0])
            _ = await sync.run()
            let deletedSent = FakeHealthServer.deleted.contains(WorkoutMapper.id(workouts[0].uuid))

            // The link died on the server: the app lets it go.
            show("unlinking")
            FakeHealthServer.status = 401
            _ = try await HealthHarness.write(HealthHarness.seeds[2], to: store)
            // The observer may get there first: either way the token goes.
            _ = await sync.run()
            let unlinked = HealthLinkStore.shared.token == nil

            let bearer = FakeHealthServer.received.allSatisfy { $0.authorization == "Bearer \(HealthHarness.token)" }
            show([
                "done",
                "sent=\(types.joined(separator: ","))",
                "initial=\(firstInitial == true)",
                "hr=\(run?["hr_avg"] as? Int ?? 0)/\(run?["hr_max"] as? Int ?? 0)",
                "zone=\(run?["zone_offset"] as? Int ?? 0)",
                "route=\(route.count)/\(routeShape)",
                "lateroute=\(lateRoute)",
                "latedistance=\(Int(lateDistance))",
                "later=\(laterIds.count)",
                "quiet=\(quiet)",
                "deleted=\(deletedSent)",
                "unlinked=\(unlinked)",
                "bearer=\(bearer)"
            ].joined(separator: " "))
        } catch {
            show("error \(error)")
        }
    }
}
#endif
