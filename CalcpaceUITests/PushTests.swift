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
    // Navigator to start before it opens, on top of the home page: Back
    // leads there.
    func testATapThatLaunchesTheAppOpensThePage() throws {
        let relay = try relayDirectory()
        launch().terminate()

        let body = send(path: "/news", through: relay)
        tapBanner(saying: body)

        let app = XCUIApplication()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30), "the tap did not open the app")
        assertOnNews(app).tap()
        assertOnHome(app)
        XCTAssertFalse(app.navigationBars.firstMatch.exists, "the bar stayed on the home page after Back")
        attachScreenshot(of: app, named: "push-back-home")
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

        assertOnHome(app)
        return app
    }

    // The home page's quick calculator: its fields are the first thing it draws.
    private func assertOnHome(_ app: XCUIApplication) {
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 30), "no web view")
        XCTAssertTrue(app.webViews.firstMatch.textFields.firstMatch.waitForExistence(timeout: 60), "calcpace.app did not load")
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

    // The news page under the app's bar, with Back: returns Back.
    @discardableResult
    private func assertOnNews(_ app: XCUIApplication) -> XCUIElement {
        let bar = app.navigationBars.firstMatch
        let title = bar.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "News")).firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 60), "the news page did not open")

        // With backButtonDisplayMode .minimal, Back is an arrow with no
        // title. UIKit's identifier for it is "BackButton"; its label is the
        // previous page's title, or "Back" when that page had none yet (the
        // home still loading on a cold start). The bar's buttons go to the
        // log, should that ever change.
        let buttons = bar.buttons.allElementsBoundByIndex.map { "identifier=\($0.identifier) label=\($0.label)" }
        print("navigation bar buttons: \(buttons)")
        add(XCTAttachment(string: buttons.joined(separator: "\n")))
        let back = bar.buttons.matching(NSPredicate(format: "identifier == 'BackButton'")).firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 10), "no Back button: \(buttons)")

        Thread.sleep(forTimeInterval: 2)
        attachScreenshot(of: app, named: "push-opened")
        return back
    }

    private func attachScreenshot(of app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
