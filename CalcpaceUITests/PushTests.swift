import XCTest

// A "your run is in" notification, as APNs would bring it, and the tap on it.
// Nothing inside the simulator can send one, so the test leaves the payload
// in PUSH_DIR and the CI job's relay (ci.yml) hands it to
// `xcrun simctl push`. Without the relay (a run from Xcode) the tests skip.
//
// Signed out there is no home card to turn notifications on with, so the
// app asks at launch (-askForNotifications, debug builds only) and the test
// allows it. The page a tap opens is the site's news, which needs no
// account and is pushed under the app's bar, with Back to the home page.
final class PushTests: XCTestCase {
    private var springboard: XCUIApplication { XCUIApplication(bundleIdentifier: "com.apple.springboard") }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // The app in front: the notification shows as a banner all the same, and
    // its page opens on top of the home page.
    func testATapWithTheAppOpenOpensThePage() throws {
        let relay = try relayDirectory()
        let app = launch()

        let body = send(path: "/news", through: relay)
        tapBanner(saying: body)
        assertOnNews(app)
    }

    // The app not running: the tap launches it, and the page waits for the
    // Navigator to start before it opens.
    func testATapThatLaunchesTheAppOpensThePage() throws {
        let relay = try relayDirectory()
        launch().terminate()

        let body = send(path: "/news", through: relay)
        tapBanner(saying: body)

        let app = XCUIApplication()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30), "the tap did not open the app")
        assertOnNews(app)
    }

    private func relayDirectory() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["PUSH_DIR"], !path.isEmpty else {
            throw XCTSkip("no push relay (PUSH_DIR): CI's test step runs one")
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-askForNotifications"]
        app.launch()

        // The system's prompt, the first time only.
        let allow = springboard.buttons["Allow"]
        if allow.waitForExistence(timeout: 15) {
            attachScreenshot(of: springboard, named: "push-prompt")
            allow.tap()
        }

        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 30), "no web view")
        XCTAssertTrue(app.webViews.firstMatch.textFields.firstMatch.waitForExistence(timeout: 60), "calcpace.app did not load")
        return app
    }

    // The server's payload, with a body of its own to find the banner by:
    // older notifications stay in the list.
    private func send(path: String, through relay: URL) -> String {
        let body = "10.2 km at 5:12/km · \(UUID().uuidString.prefix(8))"
        let payload: [String: Any] = [
            "Simulator Target Bundle": "app.calcpace.ios",
            "aps": ["alert": ["title": "Your run is in", "body": body], "sound": "default"] as [String: Any],
            "path": path
        ]
        let file = relay.appendingPathComponent("push.apns")
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: payload).write(to: file, options: .atomic))
        return body
    }

    // A banner stays up a few seconds: it is tapped as soon as it shows.
    private func tapBanner(saying body: String) {
        let banner = springboard.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", body)).firstMatch
        guard banner.waitForExistence(timeout: 60) else {
            attachScreenshot(of: springboard, named: "no-banner")
            return XCTFail("no notification banner")
        }
        attachScreenshot(of: springboard, named: "push-banner")
        banner.tap()
    }

    private func assertOnNews(_ app: XCUIApplication) {
        let back = app.navigationBars.buttons.firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 60), "the page did not open under a Back button")
        let title = app.navigationBars.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "News")).firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 60), "the news page did not open")
        Thread.sleep(forTimeInterval: 2)
        attachScreenshot(of: app, named: "push-opened")
    }

    private func attachScreenshot(of app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
