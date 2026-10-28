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

    // The front page's quick calculator, a screen pushed from it and back,
    // then a tab of the bottom bar: what someone does in the first minute,
    // and the part of the video worth watching.
    func testPredictsARaceAndChangesTabs() throws {
        let app = launch()
        let webView = app.webViews.firstMatch
        XCTAssertFalse(app.navigationBars.firstMatch.exists, "the front page is a tab root: the site's header only")

        // A 10K in 50:00, the known race the picker starts on.
        tap(webView.buttons["50:00"].firstMatch)
        tap(webView.buttons["Predict Marathon"].firstMatch)
        // A link only the result draws: "VO2max" is on the page before it.
        let details = webView.links.matching(NSPredicate(format: "label BEGINSWITH %@", "See full details")).firstMatch
        XCTAssertTrue(details.waitForExistence(timeout: 30), "no prediction")
        // The result is drawn under the button, below the fold. A slow drag
        // held at its end, not a swipe, so the page stops where the finger does.
        let from = webView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
        let to = webView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        from.press(forDuration: 0.1, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0.3)
        pause()
        attachScreenshot(of: app, named: "prediction")

        // The calculator is not a tab: it is pushed, under the app's bar.
        tap(details)
        let back = app.navigationBars.buttons.firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 30), "the calculator did not open under a Back button")
        pause()
        attachScreenshot(of: app, named: "pushed")

        back.tap()
        XCTAssertTrue(webView.buttons["Predict Marathon"].firstMatch.waitForExistence(timeout: 30), "back did not return to the front page")
        pause()
        XCTAssertFalse(app.navigationBars.firstMatch.exists, "the bar stayed on the front page after Back")

        // A tab replaces the root: no bar, nothing to go back to.
        tap(webView.links["Convert"].firstMatch)
        XCTAssertTrue(webView.buttons["Predict Marathon"].firstMatch.waitForNonExistence(timeout: 30), "the converter did not open")
        pause()
        XCTAssertFalse(app.navigationBars.firstMatch.exists, "a tab opened under the app's bar")
        attachScreenshot(of: app, named: "tab")
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
