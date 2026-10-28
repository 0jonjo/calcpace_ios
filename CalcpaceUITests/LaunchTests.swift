import XCTest

// Opens the real site, so a run needs the network. Its screenshots and the
// simulator video are the CI artifact.
final class LaunchTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testOpensCalcpace() throws {
        let app = XCUIApplication()
        app.launch()

        let webView = app.webViews.firstMatch
        XCTAssertTrue(webView.waitForExistence(timeout: 30), "no web view")

        // The calculator's fields: a Cloudflare challenge page also says
        // "calcpace.app", but has none.
        XCTAssertTrue(webView.textFields.firstMatch.waitForExistence(timeout: 60), "calcpace.app did not load")
        XCTAssertFalse(webView.staticTexts["Just a moment..."].exists, "Cloudflare challenge instead of the site")

        attachScreenshot(of: app, named: "home")
    }

    private func attachScreenshot(of app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
