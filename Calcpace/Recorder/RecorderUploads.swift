import BackgroundTasks
import Network
import UIKit
import UserNotifications
import WebKit

extension Notification.Name {
    /// A run's place in the outbox changed, or one went up.
    static let recorderUploadsChanged = Notification.Name("app.calcpace.recorder.uploads")
}

/// The way up for the runs in the `Outbox`: POST /recordings, oldest first,
/// as the athlete signed in to the WebView (its session cookie, and the
/// app's own header in place of a form's CSRF token; the contract is
/// calcpace_web's RecorderUploadsController). The Android app's
/// RecorderUploads.kt and RecorderUploadWorker.kt. Each answer goes by
/// `UploadPlan.outcome`:
///
/// - done: the phone's copy goes, and the run's edit page opens;
/// - signed out / no profile: the run waits for the app to come back
///   (`kick`), the rest of the queue with it;
/// - refused: kept for the athlete to share, and the queue goes on;
/// - anything else: tried again later, backing off from 30 s to 30 min while
///   the app is up, when the network comes back, and from a background
///   refresh iOS runs when it sees fit (`taskId`).
///
/// One upload at a time. Never logs the cookie or the file. Main thread only.
@MainActor
final class RecorderUploads {
    static let shared = RecorderUploads()

    /// The background refresh that sends what is left with the app closed
    /// (BGTaskSchedulerPermittedIdentifiers in the Info.plist).
    nonisolated static let taskId = "app.calcpace.ios.recorder-upload"
    static let header = "X-Calcpace-Recorder"
    private static let kickEvery: TimeInterval = 30
    private static let firstBackoff: TimeInterval = 30
    private static let maxBackoff: TimeInterval = 30 * 60
    private static let maxAnswerBytes = 16_384

    struct Arrival: Equatable {
        let recordingId: String
        let editURL: URL?
        let distanceMeters: Double
    }

    /// The run being posted right now, if any.
    private(set) var sendingId: String?
    /// The last run that went up since launch, for the screen to say so.
    private(set) var lastArrival: Arrival?
    /// Whether the phone has a network, as far as Network.framework knows.
    private(set) var online = true
    /// The recording screen, while it is in front: true when it opened the
    /// run's page itself, false to leave it to a notification.
    var onArrival: ((Arrival) -> Bool)?

    private var running = false
    private var background = UIBackgroundTaskIdentifier.invalid
    private var wanted = false
    private var retryParked = false
    private var retryRefused = false
    private var retryTask: Task<Void, Never>?
    private var backoff = RecorderUploads.firstBackoff
    private var lastKick: Date?
    private let monitor = NWPathMonitor()
    private var baseURL = AppDelegate.rootURL
    private var session: URLSession = RecorderUploads.makeSession(.ephemeral)

    private var outbox: Outbox { Recorder.shared.files.outbox }

    private init() {
        monitor.pathUpdateHandler = { path in
            let online = path.status == .satisfied
            Task { @MainActor in RecorderUploads.shared.networkChanged(online) }
        }
        monitor.start(queue: DispatchQueue(label: "app.calcpace.recorder.network"))
    }

    /// The UI tests' fake server, in place of the site.
    func use(configuration: URLSessionConfiguration, baseURL: URL) {
        session = Self.makeSession(configuration)
        self.baseURL = baseURL
    }

    /// After a run is saved, or a tap on "Try now". `retryParked`: also the
    /// runs waiting for a sign-in or a profile. `retryRefused`: also the ones
    /// the site refused.
    func send(retryParked: Bool = false, retryRefused: Bool = false) {
        self.retryParked = self.retryParked || retryParked || retryRefused
        self.retryRefused = self.retryRefused || retryRefused
        retryTask?.cancel()
        retryTask = nil
        if running {
            wanted = true
            return
        }
        running = true
        Task { await drain() }
    }

    /// Whenever the app comes back, at most every 30 s: the runs waiting for
    /// the app (signed out, no profile) go again, and pending ones go now.
    func kick() {
        if let lastKick, Date().timeIntervalSince(lastKick) < Self.kickEvery { return }
        lastKick = Date()
        let entries = outbox.entries()
        if entries.contains(where: { $0.state == .signedOut || $0.state == .noProfile }) {
            send(retryParked: true)
        } else if entries.contains(where: { $0.state == .pending }) {
            send()
        }
    }

    // MARK: Background refresh

    /// At launch, before it finishes: iOS hands the task only to a handler
    /// already registered.
    nonisolated static func registerBackgroundTask() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskId, using: nil) { task in
            Task { @MainActor in RecorderUploads.shared.run(task) }
        }
    }

    private func run(_ task: BGTask) {
        let work = Task { @MainActor in
            await self.waitForDrain()
            task.setTaskCompleted(success: !self.outbox.entries().contains { $0.state == .pending })
        }
        task.expirationHandler = { work.cancel() }
        send()
    }

    private func waitForDrain() async {
        while running {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if Task.isCancelled { return }
        }
    }

    private func scheduleBackgroundTask() {
        guard outbox.entries().contains(where: { $0.state == .pending }) else {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.taskId)
            return
        }
        let request = BGAppRefreshTaskRequest(identifier: Self.taskId)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    // MARK: Private

    private enum Result { case settled, retry }

    private func drain() async {
        // A run saved just before the app went to the background still goes.
        background = UIApplication.shared.beginBackgroundTask(withName: "recorder-upload") {
            MainActor.assumeIsolated { RecorderUploads.shared.endBackground() }
        }
        var result = Result.settled
        repeat {
            wanted = false
            let parked = retryParked
            let refused = retryRefused
            retryParked = false
            retryRefused = false
            result = await upload(retryParked: parked, retryRefused: refused)
        } while wanted
        running = false
        if result == .retry {
            scheduleRetry()
        } else {
            backoff = Self.firstBackoff
        }
        scheduleBackgroundTask()
        endBackground()
    }

    private func endBackground() {
        guard background != .invalid else { return }
        UIApplication.shared.endBackgroundTask(background)
        background = .invalid
    }

    private func upload(retryParked: Bool, retryRefused: Bool) async -> Result {
        let entries = outbox.entries()
        guard !entries.isEmpty else { return .settled }
        let cookie = await sessionCookie()
        for entry in entries {
            let due: Bool
            switch entry.state {
            case .pending: due = true
            case .refused: due = retryRefused
            case .signedOut, .noProfile: due = retryParked
            }
            guard due else { continue }

            let attempt = Recorder.now()
            sendingId = entry.recordingId
            changed()
            let (code, body) = cookie.isEmpty ? (401, Data()) : await post(entry, cookie: cookie)
            sendingId = nil

            switch UploadPlan.outcome(code) {
            case .done:
                outbox.remove(entry.recordingId)
                let answer = UploadPlan.answer(body)
                arrived(Arrival(recordingId: entry.recordingId, editURL: answer.flatMap { siteURL($0.editURL) },
                                distanceMeters: entry.distanceMeters))
            case .signedOut:
                park(entry, .signedOut, attempt)
                return .settled
            case .noProfile:
                park(entry, .noProfile, attempt)
                return .settled
            case .refused:
                var refused = entry
                refused.state = .refused
                refused.lastAttemptAt = attempt
                outbox.update(refused)
                changed()
            case .retry:
                var later = entry
                later.lastAttemptAt = attempt
                outbox.update(later)
                changed()
                return .retry
            }
        }
        return .settled
    }

    private func park(_ entry: Outbox.Entry, _ state: Outbox.State, _ attempt: Int64) {
        var parked = entry
        parked.state = state
        parked.lastAttemptAt = attempt
        outbox.update(parked)
        changed()
        // Once, when it starts waiting.
        if entry.state != state { notifyParked(parked) }
    }

    private func scheduleRetry() {
        let delay = backoff
        backoff = min(backoff * 2, Self.maxBackoff)
        retryTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self.retryTask = nil
            self.send()
        }
    }

    private func networkChanged(_ online: Bool) {
        let cameBack = online && !self.online
        self.online = online
        changed()
        if cameBack, !running, outbox.entries().contains(where: { $0.state == .pending }) { send() }
    }

    // The WebView's cookies for the site, as a Cookie header ("" when signed out).
    private func sessionCookie() async -> String {
        let host = baseURL.host
        let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
            .filter { CsvExport.cookie(for: $0.domain, isSentTo: host) }
        return HTTPCookie.requestHeaderFields(with: cookies)["Cookie"] ?? ""
    }

    // The status and the first bytes of the answer, or noAnswer when there was none.
    private func post(_ entry: Outbox.Entry, cookie: String) async -> (Int, Data) {
        guard let gpx = try? Data(contentsOf: outbox.gpx(entry.recordingId)) else {
            // Gone between the listing and now (sent by a run before), or unreadable.
            return (UploadPlan.noAnswer, Data())
        }
        let form = RecorderForm(fields: [
            ("recording_uuid", entry.recordingId),
            ("started_at", UploadPlan.startedAt(entry.startedAt, utcOffsetSeconds: entry.utcOffsetSeconds)),
            ("utc_offset", String(entry.utcOffsetSeconds)),
            ("app_version", Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
        ], file: ("gpx", entry.filename, "application/gpx+xml", gpx))

        var request = URLRequest(url: baseURL.appendingPathComponent("recordings"))
        request.httpMethod = "POST"
        request.httpBody = form.body
        request.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("1", forHTTPHeaderField: Self.header)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("\(AppUserAgent.prefix()) (Recorder)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await session.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? UploadPlan.noAnswer
            return (code, data.prefix(Self.maxAnswerBytes))
        } catch {
            return (UploadPlan.noAnswer, Data())
        }
    }

    // The edit page the site named, only on the site itself.
    private func siteURL(_ text: String) -> URL? {
        guard let url = URL(string: text), url.scheme == baseURL.scheme, url.host == baseURL.host,
              url.port == baseURL.port, url.user == nil, url.password == nil
        else { return nil }
        return url
    }

    private func arrived(_ arrival: Arrival) {
        lastArrival = arrival
        changed()
        if onArrival?(arrival) == true { return }
        RecorderNotices.uploaded(arrival)
    }

    private func notifyParked(_ entry: Outbox.Entry) {
        RecorderNotices.parked(entry)
    }

    private func changed() {
        NotificationCenter.default.post(name: .recorderUploadsChanged, object: self)
    }

    private static func makeSession(_ configuration: URLSessionConfiguration) -> URLSession {
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 180
        return URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }

    // A redirect is something in between (a sign-in page, a captive portal):
    // the cookie never follows it, and the run is tried again later.
    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}

/// The recorder's local notifications: "your run is up" (a tap opens its
/// edit page), "couldn't upload yet" (a tap opens the app), and the
/// watchdog's "recording stopped" (`Recorder`; a tap opens the recording
/// screen). `PushNotifications` routes their taps.
enum RecorderNotices {
    static let urlKey = "recorder_url"
    static let openKey = "recorder_open"
    private static let parkedId = "recorder.parked"

    static func uploaded(_ arrival: RecorderUploads.Arrival) {
        let distance = RunFormat.distance(arrival.distanceMeters, unit: RecorderPrefs.unit, locale: RecorderLanguage.locale)
        var info: [String: Any] = [:]
        if let url = arrival.editURL { info[urlKey] = url.absoluteString }
        post(id: "recorder.uploaded.\(arrival.recordingId)",
             title: RecorderStrings.format("recorder_notif_uploaded", distance),
             body: RecorderStrings.text("recorder_notif_uploaded_body"), info: info)
    }

    static func parked(_ entry: Outbox.Entry) {
        let distance = RunFormat.distance(entry.distanceMeters, unit: RecorderPrefs.unit, locale: RecorderLanguage.locale)
        let key = entry.state == .noProfile ? "recorder_no_profile_body" : "recorder_signed_out_body"
        post(id: parkedId, title: RecorderStrings.text("recorder_notif_parked"),
             body: RecorderStrings.format(key, distance), info: [:])
    }

    /// The page a tapped notification opens: a URL on the site only.
    static func url(from userInfo: [AnyHashable: Any], rootURL: URL) -> URL? {
        guard let text = userInfo[urlKey] as? String, let url = URL(string: text),
              url.scheme == rootURL.scheme, url.host == rootURL.host, url.port == rootURL.port,
              url.user == nil, url.password == nil
        else { return nil }
        return url
    }

    static func opensRecorder(_ userInfo: [AnyHashable: Any]) -> Bool {
        userInfo[openKey] as? Bool == true
    }

    private static func post(id: String, title: String, body: String, info: [String: Any]) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = info
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }
}
