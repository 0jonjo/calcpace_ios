import UIKit
import XCTest

// Signed in to the real site with the shared demo account (calcpace_web's
// User::DEMO_EMAIL): what only a signed-in athlete reaches, and what I1 left
// to check. The runs list, its CSV export reaching the share sheet, the run
// file picker, account deletion and the privacy policy, each in the app and
// none in Safari, then signing out.
//
// App Store and Google Play reviewers share this account, so the test leaves
// it as it found it: it reads and never writes. No file is picked, no run is
// logged, nothing in Settings changes. The deletion page is only opened: for
// the demo account the site draws no form there, just a sentence saying it is
// disabled (settings/deletions/show), and AccountsController refuses the
// deletion itself (refuse_on_demo_account) should anything ever post it. The
// one row the run adds is its own session, which signing out removes.
//
// The credentials come from a file CI writes from the DEMO_EMAIL and
// DEMO_PASSWORD secrets (ci.yml), named in DEMO_ACCOUNT (TEST_RUNNER_DEMO_ACCOUNT
// on the xcodebuild line): {"email": "...", "password": "..."}. Without it,
// as on a pull request, the test skips. Neither is typed: XCTest writes what
// typeText types into the result bundle, which is the public CI artifact, so
// both go in through the pasteboard and the field's Paste.
//
// The simulator reads English: the labels are the site's English ones.
final class DemoAccountTests: XCTestCase {
    private struct Account: Decodable {
        let email: String
        let password: String
    }

    private var safari: XCUIApplication { XCUIApplication(bundleIdentifier: "com.apple.mobilesafari") }
    private var springboard: XCUIApplication { XCUIApplication(bundleIdentifier: "com.apple.springboard") }

    // Whether the run signed out on its own, or the teardown must.
    private var signedOut = false

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testTheDemoAccountStaysInTheApp() throws {
        let account = try demoAccount()
        let app = XCUIApplication()
        app.launch()
        let webView = app.webViews.firstMatch
        XCTAssertTrue(webView.waitForExistence(timeout: 30), "no web view")

        // A session must not outlive a failure: the next tests expect the
        // signed-out front page, and the account its sessions.
        signedOut = false
        addTeardownBlock { [unowned self] in
            if !self.signedOut { self.signOutIfSignedIn(app) }
        }
        // The pasteboard is the runner's (paste), and a failure stops the
        // test before a defer is sure to run: emptied here as well.
        addTeardownBlock {
            UIPasteboard.general.items = []
        }
        signIn(account, app: app)

        // (a) The runs list, a tab root.
        tap(control("Training", in: webView), "the Training tab", in: webView)
        XCTAssertTrue(text("My Activities", in: webView).waitForExistence(timeout: 60), "the runs list did not open")
        attachScreenshot(of: app, named: "demo-activities")

        checkCsvExport(app)
        checkFilePicker(app)
        checkAccountDeletion(app)
        checkPrivacyPolicy(app)

        // (f) Signing out lands on the sign-in page.
        tapInMenu(control("Sign out", in: webView), "Sign out", app: app)
        XCTAssertTrue(text("Sign in to Calcpace", in: webView).waitForExistence(timeout: 60), "signing out did not reach the sign-in page")
        XCTAssertFalse(control("Training", in: webView).exists, "still signed in after signing out")
        signedOut = true
        attachScreenshot(of: app, named: "demo-signed-out")
    }

    // MARK: The checks

    // (c) The list's Export, then its download link: the app fetches the CSV
    // and hands it to the share sheet (CsvExportRouteDecisionHandler), which
    // shows the file's name. A failed fetch shows an alert instead.
    private func checkCsvExport(_ app: XCUIApplication) {
        let webView = app.webViews.firstMatch
        tap(control("Export", in: webView), "Export", in: webView)
        let download = webView.links.matching(NSPredicate(format: "label BEGINSWITH %@", "Download CSV")).firstMatch
        tap(download, "the Download CSV link (the demo account has runs of its own)", in: webView)

        let sheet = app.otherElements["ActivityListView"]
        let fileName = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "calcpace_activities")).firstMatch
        let failure = app.alerts.firstMatch
        let shown = waitForAny([sheet, fileName, failure], timeout: 60)
        attachScreenshot(of: app, named: "demo-csv-share-sheet")
        guard let shown, shown != failure else {
            attachHierarchy(of: app, named: "no-share-sheet")
            return XCTFail(failure.exists ? "the export failed: \(failure.label)" : "no share sheet for the CSV")
        }

        let close = app.buttons["Close"]
        if close.waitForExistence(timeout: 5) {
            close.tap()
        } else {
            // Dragged down by its top edge.
            let frame = shown.frame
            let top = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.midX, dy: max(frame.minY, 0) + 10))
            top.press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98)))
        }
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 15) && fileName.waitForNonExistence(timeout: 15), "the share sheet did not close")
        XCTAssertTrue(text("My Activities", in: webView).waitForExistence(timeout: 15), "the runs list is gone after the share sheet")
    }

    // (b) The bar's "+" ("Log"), "Import file", and the file card's "Choose
    // file": the system's document picker opens over the app, and is
    // cancelled. Nothing is picked, nothing is sent.
    private func checkFilePicker(_ app: XCUIApplication) {
        let webView = app.webViews.firstMatch
        tap(control("Log", in: webView), "the Log tab", in: webView)
        tap(control("Import file", in: webView), "Import file", in: webView)
        let chooseFile = text("Choose file", in: webView)
        tap(chooseFile, "Choose file", in: webView)

        // WebKit goes straight to the picker for a GPX/FIT/TCX input; a
        // menu first, should a version show one, leads to it.
        let pickerCancel = app.navigationBars.buttons["Cancel"]
        let pickerSigns = [pickerCancel, app.buttons["Browse"], app.buttons["Recents"], app.tabBars.firstMatch]
        let menuItem = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label IN %@", ["Choose File", "Choose Files"])).firstMatch
        var shown = waitForAny(pickerSigns + [menuItem], timeout: 30)
        if shown == menuItem {
            menuItem.tap()
            shown = waitForAny(pickerSigns, timeout: 30)
        }
        attachScreenshot(of: app, named: "demo-file-picker")
        guard shown != nil else {
            attachHierarchy(of: app, named: "no-file-picker")
            return XCTFail("no document picker after Choose file")
        }
        assertInTheApp(app, "the file picker")

        let cancel = waitForAny([pickerCancel, app.buttons["Cancel"], app.buttons["Close"]], timeout: 10)
        guard let cancel else {
            attachHierarchy(of: app, named: "no-picker-cancel")
            return XCTFail("the document picker has no Cancel")
        }
        cancel.tap()
        XCTAssertTrue(pickerCancel.waitForNonExistence(timeout: 15), "the document picker did not close")
        XCTAssertTrue(chooseFile.waitForExistence(timeout: 15), "the import form is gone after cancelling")

        goBack(app)
        XCTAssertTrue(text("My Activities", in: webView).waitForExistence(timeout: 30), "Back did not return to the runs list")
    }

    // (d) Settings, then "Delete account": the page opens pushed in the app,
    // and for the demo account says deletion is disabled, with no password
    // to type and no button to press.
    private func checkAccountDeletion(_ app: XCUIApplication) {
        let webView = app.webViews.firstMatch
        let settings = webView.links.matching(NSPredicate(format: "label CONTAINS %@", "Settings")).firstMatch
        tapInMenu(settings, "the Settings card", app: app)
        XCTAssertTrue(app.navigationBars.staticTexts["Settings"].waitForExistence(timeout: 60), "Settings did not open under the app's bar")

        let row = webView.links.matching(NSPredicate(format: "label BEGINSWITH %@", "Delete account")).firstMatch
        tap(row, "the Delete account row", in: webView)
        XCTAssertTrue(app.navigationBars.staticTexts["Delete account"].waitForExistence(timeout: 60), "the deletion page did not open under the app's bar")
        let refusal = webView.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "This is a demo account")).firstMatch
        XCTAssertTrue(refusal.waitForExistence(timeout: 30), "the deletion page does not say the demo account cannot be deleted")
        XCTAssertFalse(webView.secureTextFields.firstMatch.exists, "the deletion page asks the demo account for its password")
        XCTAssertFalse(control("Delete my account", in: webView).exists, "the deletion page offers the demo account the button")
        assertInTheApp(app, "the deletion page")
        attachScreenshot(of: app, named: "demo-delete-account")

        goBack(app)
        XCTAssertTrue(app.navigationBars.staticTexts["Settings"].waitForExistence(timeout: 30), "Back did not return to Settings")
        goBack(app)
        XCTAssertTrue(text("My Activities", in: webView).waitForExistence(timeout: 30), "Back did not return to the runs list")
    }

    // (e) The menu's "Privacy Policy": a pushed screen under the app's bar,
    // with Back, not Safari.
    private func checkPrivacyPolicy(_ app: XCUIApplication) {
        let webView = app.webViews.firstMatch
        tapInMenu(control("Privacy Policy", in: webView), "Privacy Policy", app: app)
        XCTAssertTrue(app.navigationBars.staticTexts["Privacy Policy"].waitForExistence(timeout: 60), "the privacy policy did not open under the app's bar")
        XCTAssertTrue(text("Privacy Policy", in: webView).waitForExistence(timeout: 30), "the privacy policy is not in the web view")
        assertInTheApp(app, "the privacy policy")
        attachScreenshot(of: app, named: "demo-privacy")

        goBack(app)
        XCTAssertTrue(text("My Activities", in: webView).waitForExistence(timeout: 30), "Back did not return to the runs list")
    }

    // MARK: Signing in and out

    // From the front page's menu to the sign-in page, whose two fields are
    // filled by pasting (see the top) and its form sent.
    private func signIn(_ account: Account, app: XCUIApplication) {
        let webView = app.webViews.firstMatch
        // The front page's calculator: a Cloudflare challenge has no field.
        XCTAssertTrue(webView.textFields.firstMatch.waitForExistence(timeout: 60), "calcpace.app did not load")
        tapInMenu(control("Sign in", in: webView), "Sign in", app: app)
        XCTAssertTrue(text("Sign in to Calcpace", in: webView).waitForExistence(timeout: 60), "the sign-in page did not open")

        let email = webView.textFields.firstMatch
        paste(account.email, into: email, named: "email", app: app) { ($0.value as? String) == account.email }
        let password = webView.secureTextFields.firstMatch
        paste(account.password, into: password, named: "password", app: app) { !(($0.value as? String) ?? "").isEmpty }

        // The keyboard away first: on a small phone it covers the button.
        text("Sign in to Calcpace", in: webView).tap()
        _ = app.keyboards.firstMatch.waitForNonExistence(timeout: 5)
        tap(webView.buttons["Sign in"], "the Sign in button", in: webView)

        let training = control("Training", in: webView)
        let refused = webView.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ OR label CONTAINS %@ OR label CONTAINS %@",
                                                               "Try another email address or password", "Try again later", "Too many requests")).firstMatch
        let landed = waitForAny([training, refused], timeout: 60)
        guard landed == training else {
            attachScreenshot(of: app, named: "demo-sign-in-failed")
            return XCTFail(refused.exists ? "the site refused the demo sign-in: \(refused.label)" : "not signed in")
        }
        attachScreenshot(of: app, named: "demo-signed-in")
    }

    // A failed run's way out, best effort: back to a root, whose header has
    // the menu, and Sign out there.
    private func signOutIfSignedIn(_ app: XCUIApplication) {
        guard app.state == .runningForeground else { return }
        let webView = app.webViews.firstMatch
        for sheetButton in [app.buttons["Close"], app.navigationBars.buttons["Cancel"]] where sheetButton.exists {
            sheetButton.tap()
        }
        let back = backButton(app)
        for _ in 0 ..< 5 where back.exists {
            back.tap()
            _ = control("Menu", in: webView).waitForExistence(timeout: 5)
        }
        let training = control("Training", in: webView)
        if training.exists, !control("Menu", in: webView).exists { training.tap() }

        let menu = control("Menu", in: webView)
        guard menu.waitForExistence(timeout: 15) else { return }
        let signOut = control("Sign out", in: webView)
        if !signOut.exists { menu.tap() }
        guard signOut.waitForExistence(timeout: 10) else { return }
        reveal(signOut, in: webView)
        signOut.tap()
        _ = text("Sign in to Calcpace", in: webView).waitForExistence(timeout: 30)
    }

    // MARK: Helpers

    private func demoAccount() throws -> Account {
        guard let path = ProcessInfo.processInfo.environment["DEMO_ACCOUNT"], !path.isEmpty else {
            throw XCTSkip("no demo account (DEMO_ACCOUNT): CI writes one from the DEMO_EMAIL and DEMO_PASSWORD secrets")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let account = try JSONDecoder().decode(Account.self, from: data)
        guard !account.email.isEmpty, !account.password.isEmpty else {
            throw XCTSkip("the demo account file has an empty email or password")
        }
        return account
    }

    // Through the pasteboard and the field's own Paste, never typeText. The
    // menu shows on a tap of the focused field, or else on a long press. iOS
    // asks before an app reads what another put on the pasteboard, should it
    // count this paste as such; the answer is Allow.
    private func paste(_ value: String, into field: XCUIElement, named name: String, app: XCUIApplication,
                       filled: @escaping (XCUIElement) -> Bool) {
        XCTAssertTrue(field.waitForExistence(timeout: 30), "no \(name) field")
        UIPasteboard.general.string = value
        defer { UIPasteboard.general.items = [] }

        let pasteItem = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == 'Paste' AND elementType IN %@",
                                  [XCUIElement.ElementType.menuItem, .button].map { NSNumber(value: $0.rawValue) }))
            .firstMatch
        field.tap()
        if !pasteItem.waitForExistence(timeout: 3) {
            field.tap()
            if !pasteItem.waitForExistence(timeout: 3) {
                field.press(forDuration: 1.2)
            }
        }
        guard pasteItem.waitForExistence(timeout: 5) else {
            attachScreenshot(of: app, named: "no-paste-\(name)")
            return XCTFail("no Paste in the \(name) field's menu")
        }
        pasteItem.tap()

        let allow = springboard.buttons["Allow Paste"]
        let allowInApp = app.buttons["Allow Paste"]
        let done = NSPredicate { _, _ in filled(field) || allow.exists || allowInApp.exists }
        _ = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: done, object: nil)], timeout: 10)
        for button in [allow, allowInApp] where button.exists {
            button.tap()
        }
        let pasted = NSPredicate { _, _ in filled(field) }
        let result = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: pasted, object: nil)], timeout: 10)
        XCTAssertEqual(result, .completed, "the \(name) did not reach its field")
    }

    // The web page's tap targets: a link, a button, or what WebKit makes of
    // one that opens something (aria-haspopup, aria-expanded).
    private func control(_ label: String, in webView: XCUIElement) -> XCUIElement {
        let types: [XCUIElement.ElementType] = [.link, .button, .popUpButton, .disclosureTriangle]
        return webView.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@ AND elementType IN %@", label, types.map { NSNumber(value: $0.rawValue) }))
            .firstMatch
    }

    // Anything the page shows with that label: a heading, a label, a link.
    private func text(_ label: String, in webView: XCUIElement) -> XCUIElement {
        webView.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    private func tap(_ element: XCUIElement, _ name: String, in webView: XCUIElement,
                     file: StaticString = #filePath, line: UInt = #line) {
        guard element.waitForExistence(timeout: 30) else {
            attachScreenshot(of: XCUIApplication(), named: "not-found")
            return XCTFail("\(name) not found", file: file, line: line)
        }
        reveal(element, in: webView)
        element.tap()
    }

    // Below the fold, or under the fixed tab bar: scrolled up into reach.
    private func reveal(_ element: XCUIElement, in webView: XCUIElement) {
        for _ in 0 ..< 6 where !element.isHittable {
            webView.swipeUp(velocity: .slow)
        }
    }

    // The site's menu, from a root's header (pushed screens have none). Its
    // links are in the page only while it is open, and on a phone "Privacy
    // Policy" is in no other place (the footer is for wider screens): that
    // link says whether it is open, since a tap on Menu closes an open one.
    private func tapInMenu(_ element: XCUIElement, _ name: String, app: XCUIApplication,
                           file: StaticString = #filePath, line: UInt = #line) {
        let webView = app.webViews.firstMatch
        if !control("Privacy Policy", in: webView).exists {
            tap(control("Menu", in: webView), "the site's Menu button", in: webView, file: file, line: line)
            XCTAssertTrue(control("Privacy Policy", in: webView).waitForExistence(timeout: 15), "the site's menu did not open",
                          file: file, line: line)
        }
        tap(element, "\(name) in the menu", in: webView, file: file, line: line)
    }

    // UIKit's Back: an arrow whose identifier is "BackButton" (PushTests).
    private func backButton(_ app: XCUIApplication) -> XCUIElement {
        app.navigationBars.buttons.matching(NSPredicate(format: "identifier == 'BackButton'")).firstMatch
    }

    private func goBack(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let back = backButton(app)
        XCTAssertTrue(back.waitForExistence(timeout: 30), "no Back button", file: file, line: line)
        back.tap()
    }

    // Still the app in front, and Safari nowhere near it.
    private func assertInTheApp(_ app: XCUIApplication, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(app.state, .runningForeground, "\(what) took the app out of the front", file: file, line: line)
        XCTAssertNotEqual(safari.state, .runningForeground, "\(what) opened in Safari", file: file, line: line)
    }

    // The first of these to show, or nil when none does in time.
    private func waitForAny(_ elements: [XCUIElement], timeout: TimeInterval) -> XCUIElement? {
        let any = NSPredicate { _, _ in elements.contains { $0.exists } }
        guard XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: any, object: nil)], timeout: timeout) == .completed else {
            return nil
        }
        return elements.first { $0.exists }
    }

    private func attachScreenshot(of app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // What the app showed when an element was missing, to find its label by.
    private func attachHierarchy(of app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(string: app.debugDescription)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
