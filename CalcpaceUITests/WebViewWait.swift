import XCTest

extension XCTestCase {
    // The app's web view. On a freshly booted CI simulator the first launch
    // has taken more than 30 s to bring it up (WebKit's processes start cold,
    // and the runner logs failed GPU process assertions), then passed on a
    // rerun. When it never shows, what was on screen goes with the failure,
    // to tell a slow simulator from an app that opened blank. "debug-" is
    // the prefix screenshots.yml lets out of the runner too; it is safe
    // there only because every caller waits right after launch, before any
    // sign-in: the tree holds whatever is on screen.
    @discardableResult
    func waitForWebView(in app: XCUIApplication, timeout: TimeInterval = 90, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let webView = app.webViews.firstMatch
        if !webView.waitForExistence(timeout: timeout) {
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "debug-no-web-view"
            screenshot.lifetime = .keepAlways
            add(screenshot)
            let tree = XCTAttachment(string: app.debugDescription)
            tree.name = "debug-no-web-view-tree"
            tree.lifetime = .keepAlways
            add(tree)
            XCTFail("no web view after \(Int(timeout)) s (app state \(app.state.rawValue))", file: file, line: line)
        }
        return webView
    }
}
