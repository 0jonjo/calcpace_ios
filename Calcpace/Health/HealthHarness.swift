#if DEBUG
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

    static let writeTypes: Set<HKSampleType> = [HealthReader.workoutType, HealthReader.distanceType, HealthReader.heartRateType]

    struct Seed {
        let activity: HKWorkoutActivityType
        let indoor: Bool
        let meters: Double?
        let hoursAgo: Double
        let minutes: Double
        let heartRates: [Double]
    }

    /// A run with its heart rate, a treadmill run, a walk, and a ride that
    /// is no run: three sessions to send.
    static let seeds = [
        Seed(activity: .running, indoor: false, meters: 5000, hoursAgo: 50, minutes: 25, heartRates: [150, 160]),
        Seed(activity: .running, indoor: true, meters: 3000, hoursAgo: 30, minutes: 18, heartRates: []),
        Seed(activity: .walking, indoor: false, meters: 2000, hoursAgo: 20, minutes: 24, heartRates: []),
        Seed(activity: .cycling, indoor: false, meters: nil, hoursAgo: 10, minutes: 40, heartRates: [])
    ]

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
        return workout
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
            try await store.requestAuthorization(toShare: HealthHarness.writeTypes, read: HealthReader.readTypes)
            // A simulator the test ran on before: its workouts go first.
            _ = try? await store.deleteObjects(of: HealthReader.workoutType, predicate: HKQuery.predicateForObjects(from: HKSource.default()))
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
            let firstInitial = FakeHealthServer.received.first?.body["initial"] as? Bool

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
