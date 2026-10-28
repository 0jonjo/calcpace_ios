import XCTest

// Opens the real site, so a run needs the network. Its screenshots and the
// simulator video are the CI artifact. The simulator reads English, so the
// labels below are the site's English ones (calcpace_web config/locales/en.yml).
final class LaunchTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testOpensCalcpace() throws {
        let app = launch()
        attachScreenshot(of: app, named: "home")
    }

    // The front page's quick calculator, then a tab of the bottom bar and
    // back: what someone does in the first minute, and the part of the video
    // worth watching.
    func testPredictsARaceAndChangesTabs() throws {
        let app = launch()
        let webView = app.webViews.firstMatch

        // A 10K in 50:00, the known race the picker starts on.
        tap(webView.buttons["50:00"].firstMatch)
        tap(webView.buttons["Predict Marathon"].firstMatch)
        // Drawn upper-case by CSS, which WebKit may or may not hand on.
        let vo2max = webView.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "VO2max")).firstMatch
        XCTAssertTrue(vo2max.waitForExistence(timeout: 30), "no prediction")
        pause()
        attachScreenshot(of: app, named: "prediction")

        tap(webView.links["Convert"].firstMatch)
        let back = app.navigationBars.buttons.firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 30), "the tab did not open a new screen")
        pause()
        attachScreenshot(of: app, named: "converter")

        back.tap()
        XCTAssertTrue(webView.buttons["Predict Marathon"].firstMatch.waitForExistence(timeout: 30), "back did not return to the front page")
        pause()
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launch()

        let webView = app.webViews.firstMatch
        XCTAssertTrue(webView.waitForExistence(timeout: 30), "no web view")

        // The calculator's fields: a Cloudflare challenge page also says
        // "calcpace.app", but has none.
        XCTAssertTrue(webView.textFields.firstMatch.waitForExistence(timeout: 60), "calcpace.app did not load")
        XCTAssertFalse(webView.staticTexts["Just a moment..."].exists, "Cloudflare challenge instead of the site")
        return app
    }

    private func tap(_ element: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: 30), "\(element) not found")
        element.tap()
    }

    // Long enough for someone watching the video to read the screen.
    private func pause() {
        Thread.sleep(forTimeInterval: 2)
    }

    private func attachScreenshot(of app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
