#if DEBUG
import UIKit
import WebKit

/// The UI tests' recorder run (`-recorderHarness`, RecorderTests): no site,
/// no account. A clean recorder, the recording screen over a blank page, a
/// made-up session cookie and `FakeRecorderServer` in place of the site. The
/// simulator's location comes from the CI job (`simctl location`); the test
/// drives the screen. The label says what reached the server and which page
/// the app then opened: "opened /activities/42/edit … points=… uuid=ok …".
enum RecorderHarness {
    static var isOn: Bool { ProcessInfo.processInfo.arguments.contains("-recorderHarness") }

    static let cookie = "_calcpace_session=harness"
    static let editURL = "https://calcpace.app/activities/42/edit?via=recorder"
}

/// Records what the recorder posts and answers 201 with the run's edit page,
/// as RecorderUploadsController does. Lives in the app's process, behind the
/// uploads' own URLSession only.
final class FakeRecorderServer: URLProtocol {
    private static let lock = NSLock()
    private static var _summary = "nothing"

    static var configuration: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FakeRecorderServer.self]
        return configuration
    }

    static var summary: String {
        lock.lock()
        defer { lock.unlock() }
        return _summary
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = String(decoding: request.httpBody ?? Self.read(request.httpBodyStream), as: UTF8.self)
        let uuid = Self.field("recording_uuid", in: body) ?? ""
        let start = Self.field("started_at", in: body) ?? ""
        let words = [
            "path=\(request.url?.path ?? "")",
            "points=\(body.components(separatedBy: "<trkpt ").count - 1)",
            "uuid=\(RunLog.isRecordingId(uuid) ? "ok" : "bad")",
            "start=\(start.count == 25 || start.hasSuffix("Z") ? "ok" : "bad:\(start)")",
            "header=\(request.value(forHTTPHeaderField: RecorderUploads.header) == "1")",
            "cookie=\(request.value(forHTTPHeaderField: "Cookie")?.contains(RecorderHarness.cookie) == true)",
            "creator=\(body.contains("creator=\"Calcpace iOS\""))"
        ]
        Self.lock.lock()
        Self._summary = words.joined(separator: " ")
        Self.lock.unlock()

        let response = HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"id":42,"edit_url":"\#(RecorderHarness.editURL)"}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    // The value of a text part of the multipart body.
    private static func field(_ name: String, in body: String) -> String? {
        guard let start = body.range(of: "name=\"\(name)\"\r\n\r\n") else { return nil }
        let rest = body[start.upperBound...]
        return rest.range(of: "\r\n").map { String(rest[..<$0.lowerBound]) }
    }

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

final class RecorderHarnessViewController: UIViewController {
    private let label = UILabel()
    private var started = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .white
        label.numberOfLines = 0
        label.textAlignment = .center
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

    private func run() async {
        // A clean slate before anything reads the recorder's files.
        try? FileManager.default.removeItem(at: RecorderFiles.defaultRoot.appendingPathComponent("recorder"))
        RecorderPrefs.siteLocale = "en"
        RecorderPrefs.unit = .km
        RecorderPrefs.askedNotifications = true
        let cookie = HTTPCookie(properties: [.domain: "calcpace.app", .path: "/", .name: "_calcpace_session",
                                             .value: "harness", .secure: true])!
        await WKWebsiteDataStore.default().httpCookieStore.setCookie(cookie)
        RecorderUploads.shared.use(configuration: FakeRecorderServer.configuration, baseURL: AppDelegate.rootURL)
        PushInbox.shared.ready { [weak self] url in
            self?.label.text = "opened \(url.path) \(FakeRecorderServer.summary)"
            return true
        }
        label.text = "ready"
        RecorderScreen.present(over: self)
    }
}
#endif
