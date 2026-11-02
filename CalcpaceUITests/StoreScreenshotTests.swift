import ImageIO
import UIKit
import UniformTypeIdentifiers
import XCTest

// The App Store screenshots, in English and Brazilian Portuguese, shot by
// .github/workflows/screenshots.yml on the phone sizes App Store Connect
// asks for. The front page's prediction signed out, then the rest signed in
// to the real site with the shared demo account (calcpace_web's
// User::DEMO_EMAIL), whose seed (GuestResetJob) fills every panel: the
// home, the runs list, a run with its route (the GPX "Lisboa Corrida"),
// Performance, the race calendar (narrowed to the store's part of the
// world) and the Apple Health guide (in English only:
// Language.appleHealthShot). On the way it checks what the shots once
// showed wrong: the home under the sign-in's bar, a run titled with the
// site's name, a Back from the site under the app's.
//
// Only that workflow runs it: it sets STORE_SCREENSHOTS (on the xcodebuild
// line, TEST_RUNNER_STORE_SCREENSHOTS) and the test skips without it, so
// ci.yml's pull request runs pass over it.
//
// App Store and Google Play reviewers share the demo account, so this reads
// and never writes: it opens pages and taps nothing that saves. Apple
// Health is shown by its guide, not linked (the demo account never links:
// its Settings page says so instead, and the home has no card for it). The
// one row a run adds is its own session, which signing out removes.
//
// The credentials, as in DemoAccountTests: a file the workflow writes from
// the DEMO_EMAIL and DEMO_PASSWORD secrets, named in DEMO_ACCOUNT
// (TEST_RUNNER_DEMO_ACCOUNT): {"email": "...", "password": "..."}. Neither
// is typed: XCTest writes what typeText types into the result bundle, so
// both go in through the pasteboard and the field's Paste. No screenshot is
// taken from the moment the sign-in page opens until the signed-in bar
// shows, a failure's included; the workflow uploads only the named shots,
// never the result bundle.
//
// The language: the app is launched in it (-AppleLanguages), which the web
// view's navigator.languages follows. The site's front page redirects
// itself to /pt-BR for a Portuguese device (shared/_locale_autodetect), the
// sign-in form there posts to /pt-BR and lands on /pt-BR, and every link
// from then on carries the prefix, which comes before the demo profile's
// own language (English) in ApplicationController#extract_locale.
final class StoreScreenshotTests: XCTestCase {
    private struct Account: Decodable {
        let email: String
        let password: String
    }

    // The site's words for what the run taps and waits for (calcpace_web
    // config/locales), and the system's for Paste in the app's language.
    private struct Language {
        let code: String // the folder the workflow sorts the shots into
        let arguments: [String]
        let predict: String
        let seeDetails: String
        let calculate: String
        let menu: String
        let privacy: String
        let signIn: String
        let signInTitle: String
        let signInButton: String
        let refused: [String]
        let greeting: String
        let training: String
        let activitiesTitle: String
        let performance: String
        let performanceTitle: String
        let siteBack: String
        let calendar: String
        let calendarTitle: String
        // The calendar narrowed to the store's own part of the world, which
        // also drops its "Races near you" block: that one follows the
        // runner's IP (CF-IPCountry), and the CI's is in the United States.
        let calendarFilter: String
        let calendarPlace: String
        let settings: String
        // Settings lives outside the site's /pt-BR prefix, so it and the
        // guide it links to are drawn in the profile's language, the demo
        // account's English; a Portuguese guide has no way in until the
        // guides page lists it (IosApp.public?).
        let appleHealthShot: Bool
        let appleHealthRow: String
        let guideLink: String
        let guideTitle: String
        let signOut: String
        let paste: [String]
        let allowPaste: [String]

        static let english = Language(
            code: "en-US",
            arguments: ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"],
            predict: "Predict Marathon",
            seeDetails: "See full details",
            calculate: "Calculate",
            menu: "Menu",
            privacy: "Privacy Policy",
            signIn: "Sign in",
            signInTitle: "Sign in to Calcpace",
            signInButton: "Sign in",
            refused: ["Try another email address or password", "Try again later", "Too many requests"],
            greeting: "Hi, Guest",
            training: "Training",
            activitiesTitle: "My Activities",
            performance: "Performance",
            performanceTitle: "Your performance",
            siteBack: "← Back",
            calendar: "Calendar",
            calendarTitle: "Race Calendar",
            calendarFilter: "Filter by continent",
            calendarPlace: "North America",
            settings: "Settings",
            appleHealthShot: true,
            appleHealthRow: "Apple Health",
            guideLink: "Learn how importing from the Health app works",
            guideTitle: "Apple Health in Calcpace",
            signOut: "Sign out",
            paste: ["Paste"],
            allowPaste: ["Allow Paste"]
        )

        static let portuguese = Language(
            code: "pt-BR",
            arguments: ["-AppleLanguages", "(pt-BR)", "-AppleLocale", "pt_BR"],
            predict: "Prever Maratona",
            seeDetails: "Ver detalhes",
            calculate: "Calcular",
            menu: "Menu",
            privacy: "Política de Privacidade",
            signIn: "Entrar",
            signInTitle: "Login no Calcpace",
            signInButton: "Entrar",
            refused: ["E-mail ou senha incorretos", "Tente novamente"],
            greeting: "Olá, Guest",
            training: "Treinos",
            activitiesTitle: "Minhas Atividades",
            performance: "Desempenho",
            performanceTitle: "Seu desempenho",
            siteBack: "← Voltar",
            calendar: "Calendário",
            calendarTitle: "Calendário de Corridas",
            calendarFilter: "Filtrar por país",
            calendarPlace: "Brasil",
            settings: "Configurações",
            appleHealthShot: false,
            appleHealthRow: "App Saúde",
            guideLink: "Como funciona a importação do app Saúde",
            guideTitle: "App Saúde no Calcpace",
            signOut: "Sair",
            paste: ["Colar", "Paste"],
            allowPaste: ["Permitir Colar", "Allow Paste"]
        )
    }

    private var springboard: XCUIApplication { XCUIApplication(bundleIdentifier: "com.apple.springboard") }

    private var language = Language.english
    // From the sign-in page opening until the account's home shows: no
    // screenshot of any kind, a failure's included.
    private var onSignInForm = false
    private var signedOut = false

    override func setUpWithError() throws {
        continueAfterFailure = false
        guard ProcessInfo.processInfo.environment["STORE_SCREENSHOTS"] == "1" else {
            throw XCTSkip("store screenshots only in .github/workflows/screenshots.yml (STORE_SCREENSHOTS)")
        }
    }

    func testEnglish() throws {
        try shoot(.english)
    }

    func testPortuguese() throws {
        try shoot(.portuguese)
    }

    private func shoot(_ language: Language) throws {
        self.language = language
        let account = try demoAccount()
        let app = XCUIApplication()
        app.launchArguments = language.arguments
        app.launch()
        let webView = app.webViews.firstMatch
        XCTAssertTrue(webView.waitForExistence(timeout: 30), "no web view")

        onSignInForm = false
        signedOut = false
        addTeardownBlock { [unowned self] in
            if !self.signedOut { self.signOutIfSignedIn(app) }
        }
        addTeardownBlock {
            UIPasteboard.general.items = []
        }

        // 1. The front page's prediction, signed out: a 10K in 50:00 (the
        // race and time the picker starts on), then the marathon it predicts,
        // scrolled up under the header. In Portuguese, the page has
        // redirected itself to /pt-BR first.
        let predict = webView.buttons[language.predict].firstMatch
        XCTAssertTrue(predict.waitForExistence(timeout: 60),
                      "the front page did not open in \(language.code) (no \"\(language.predict)\")")
        let details = webView.links.matching(NSPredicate(format: "label BEGINSWITH %@", language.seeDetails)).firstMatch
        // Once more if the first taps came before the page's script.
        for _ in 0 ..< 2 where !details.exists {
            tap(webView.buttons["50:00"].firstMatch, "the 50:00 chip", in: webView)
            tap(predict, language.predict, in: webView)
            _ = details.waitForExistence(timeout: 15)
        }
        guard details.exists else {
            debug("no-prediction")
            return XCTFail("no prediction")
        }
        let from = webView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
        let to = webView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        from.press(forDuration: 0.1, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0.3)
        settle(2)
        shot("01-predict")

        signIn(account, app: app)

        // 2. The account's home, where signing in lands: a root, with the
        // sign-in gone from under it (no Back, no bar).
        XCTAssertTrue(text(language.greeting, in: webView).waitForExistence(timeout: 60), "signing in did not land on the home")
        XCTAssertFalse(backButton(app).exists, "the home opened under a Back button")
        XCTAssertTrue(app.navigationBars.firstMatch.waitForNonExistence(timeout: 10), "the home opened under the app's bar")
        settle(3)
        shot("05-home")

        // 3. The runs list, a tab root.
        tap(control(language.training, in: webView), "the \(language.training) tab", in: webView)
        XCTAssertTrue(text(language.activitiesTitle, in: webView).waitForExistence(timeout: 60), "the runs list did not open")
        settle(3)
        shot("04-activities")

        // 4. The GPX run, whose page opens on its route, named in the app's
        // bar, whose Back is the only one.
        let run = webView.links.matching(NSPredicate(format: "label CONTAINS %@", "Lisboa Corrida")).firstMatch
        tap(run, "the Lisboa Corrida run", in: webView)
        XCTAssertTrue(backButton(app).waitForExistence(timeout: 60), "the run did not open under the app's bar")
        XCTAssertTrue(text("Lisboa Corrida", in: webView).waitForExistence(timeout: 60), "the run's page did not load")
        XCTAssertTrue(app.navigationBars.staticTexts["Lisboa Corrida"].waitForExistence(timeout: 10),
                      "the app's bar does not name the run")
        XCTAssertFalse(control(language.siteBack, in: webView).exists, "the run's page shows the site's Back under the app's")
        // The map's tiles come from the network after the page.
        settle(8)
        shot("02-run-map")
        goBack(app)
        XCTAssertTrue(text(language.activitiesTitle, in: webView).waitForExistence(timeout: 30), "Back did not return to the runs list")

        // 5. Performance: zones, paces, predictions and the fitness trend.
        tap(control(language.performance, in: webView), "the \(language.performance) tab", in: webView)
        XCTAssertTrue(text(language.performanceTitle, in: webView).waitForExistence(timeout: 60), "Performance did not open")
        settle(4)
        shot("03-performance")

        // 6. The race calendar, narrowed to the store's part of the world.
        tap(control(language.calendar, in: webView), "the \(language.calendar) tab", in: webView)
        XCTAssertTrue(text(language.calendarTitle, in: webView).waitForExistence(timeout: 60), "the race calendar did not open")
        choose(language.calendarPlace, in: language.calendarFilter, app: app)
        XCTAssertTrue(text(language.calendarTitle, in: webView).waitForExistence(timeout: 60), "the filtered calendar did not open")
        settle(3)
        shot("07-race-calendar")

        // 7. Apple Health: Settings, its Apple Health row (iOS app only), and
        // the guide that page links to. Nothing is linked.
        if language.appleHealthShot {
            shootAppleHealthGuide(app)
        }

        // Signing out lands on the sign-in page.
        tapInMenu(control(language.signOut, in: webView), language.signOut, app: app)
        XCTAssertTrue(text(language.signInTitle, in: webView).waitForExistence(timeout: 60), "signing out did not reach the sign-in page")
        signedOut = true
    }

    private func shootAppleHealthGuide(_ app: XCUIApplication) {
        let webView = app.webViews.firstMatch
        let settings = webView.links.matching(NSPredicate(format: "label CONTAINS %@", language.settings)).firstMatch
        tapInMenu(settings, "the Settings card", app: app)
        let row = webView.links.matching(NSPredicate(format: "label BEGINSWITH %@", language.appleHealthRow)).firstMatch
        guard row.waitForExistence(timeout: 60) else {
            debug("no-apple-health-row")
            return XCTFail("Settings did not open, or has no \(language.appleHealthRow) row")
        }
        // Low on the page: out from under the fixed tab bar first, which a
        // tap on the row would otherwise reach.
        for _ in 0 ..< 4 where row.frame.maxY > app.frame.height - 180 {
            webView.swipeUp(velocity: .slow)
        }
        row.tap()
        let guide = webView.links.matching(NSPredicate(format: "label BEGINSWITH %@", language.guideLink)).firstMatch
        XCTAssertTrue(guide.waitForExistence(timeout: 60), "the Apple Health page did not open")
        XCTAssertFalse(control(language.settings, in: webView).exists, "Settings' page shows the site's \"< Settings\" under the app's")
        tap(guide, "the Apple Health guide link", in: webView)
        XCTAssertTrue(text(language.guideTitle, in: webView).waitForExistence(timeout: 60), "the Apple Health guide did not open")
        settle(3)
        shot("06-apple-health")
        for _ in 0 ..< 3 {
            goBack(app)
            _ = app.navigationBars.firstMatch.waitForNonExistence(timeout: 5)
        }
        XCTAssertTrue(text(language.calendarTitle, in: webView).waitForExistence(timeout: 30), "Back did not return to the race calendar")
    }

    // MARK: Signing in and out (DemoAccountTests', in the run's language)

    private func signIn(_ account: Account, app: XCUIApplication) {
        let webView = app.webViews.firstMatch
        onSignInForm = true
        tapInMenu(control(language.signIn, in: webView), language.signIn, app: app)
        XCTAssertTrue(text(language.signInTitle, in: webView).waitForExistence(timeout: 60), "the sign-in page did not open")

        let email = webView.textFields.firstMatch
        paste(account.email, into: email, named: "email", app: app) { ($0.value as? String) == account.email }
        let password = webView.secureTextFields.firstMatch
        paste(account.password, into: password, named: "password", app: app) { !(($0.value as? String) ?? "").isEmpty }

        // The keyboard away first: on a small phone it covers the button.
        text(language.signInTitle, in: webView).tap()
        _ = app.keyboards.firstMatch.waitForNonExistence(timeout: 5)
        tap(webView.buttons[language.signInButton], "the sign-in button", in: webView)

        let training = control(language.training, in: webView)
        let refused = webView.staticTexts.matching(NSCompoundPredicate(orPredicateWithSubpredicates:
            language.refused.map { NSPredicate(format: "label CONTAINS %@", $0) })).firstMatch
        let landed = waitForAny([training, refused], timeout: 60)
        guard landed == training else {
            return XCTFail(refused.exists ? "the site refused the demo sign-in: \(refused.label)" : "not signed in")
        }
        onSignInForm = false
    }

    private func signOutIfSignedIn(_ app: XCUIApplication) {
        guard app.state == .runningForeground else { return }
        let webView = app.webViews.firstMatch
        let back = backButton(app)
        for _ in 0 ..< 5 where back.exists {
            back.tap()
            _ = control(language.menu, in: webView).waitForExistence(timeout: 5)
        }
        let training = control(language.training, in: webView)
        if training.exists, !control(language.menu, in: webView).exists { training.tap() }

        let menu = control(language.menu, in: webView)
        guard menu.waitForExistence(timeout: 15) else { return }
        let signOut = control(language.signOut, in: webView)
        if !signOut.exists { menu.tap() }
        guard signOut.waitForExistence(timeout: 10) else { return }
        reveal(signOut, in: webView)
        signOut.tap()
        _ = text(language.signInTitle, in: webView).waitForExistence(timeout: 30)
    }

    // MARK: Helpers

    private func demoAccount() throws -> Account {
        guard let path = ProcessInfo.processInfo.environment["DEMO_ACCOUNT"], !path.isEmpty else {
            throw XCTSkip("no demo account (DEMO_ACCOUNT): the workflow writes one from the DEMO_EMAIL and DEMO_PASSWORD secrets")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let account = try JSONDecoder().decode(Account.self, from: data)
        guard !account.email.isEmpty, !account.password.isEmpty else {
            throw XCTSkip("the demo account file has an empty email or password")
        }
        return account
    }

    // Through the pasteboard and the field's own Paste, never typeText.
    private func paste(_ value: String, into field: XCUIElement, named name: String, app: XCUIApplication,
                       filled: @escaping (XCUIElement) -> Bool) {
        XCTAssertTrue(field.waitForExistence(timeout: 30), "no \(name) field")
        UIPasteboard.general.string = value
        defer { UIPasteboard.general.items = [] }

        let pasteItem = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label IN %@ AND elementType IN %@", language.paste,
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
            return XCTFail("no Paste in the \(name) field's menu")
        }
        pasteItem.tap()

        let allows = language.allowPaste.flatMap { [springboard.buttons[$0], app.buttons[$0]] }
        let done = NSPredicate { _, _ in filled(field) || allows.contains { $0.exists } }
        _ = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: done, object: nil)], timeout: 10)
        for button in allows where button.exists {
            button.tap()
        }
        let pasted = NSPredicate { _, _ in filled(field) }
        let result = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: pasted, object: nil)], timeout: 10)
        XCTAssertEqual(result, .completed, "the \(name) did not reach its field")
    }

    private func control(_ label: String, in webView: XCUIElement) -> XCUIElement {
        let types: [XCUIElement.ElementType] = [.link, .button, .popUpButton, .disclosureTriangle]
        return webView.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@ AND elementType IN %@", label, types.map { NSNumber(value: $0.rawValue) }))
            .firstMatch
    }

    private func text(_ label: String, in webView: XCUIElement) -> XCUIElement {
        webView.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    private func tap(_ element: XCUIElement, _ name: String, in webView: XCUIElement,
                     file: StaticString = #filePath, line: UInt = #line) {
        guard element.waitForExistence(timeout: 30) else {
            debug("not-found")
            return XCTFail("\(name) not found", file: file, line: line)
        }
        reveal(element, in: webView)
        element.tap()
    }

    private func reveal(_ element: XCUIElement, in webView: XCUIElement) {
        for _ in 0 ..< 6 where !element.isHittable {
            webView.swipeUp(velocity: .slow)
        }
    }

    // The site's menu, from a root's header; "Privacy Policy" is in the page
    // only while it is open.
    private func tapInMenu(_ element: XCUIElement, _ name: String, app: XCUIApplication,
                           file: StaticString = #filePath, line: UInt = #line) {
        let webView = app.webViews.firstMatch
        if !control(language.privacy, in: webView).exists {
            tap(control(language.menu, in: webView), "the site's Menu button", in: webView, file: file, line: line)
            XCTAssertTrue(control(language.privacy, in: webView).waitForExistence(timeout: 15), "the site's menu did not open",
                          file: file, line: line)
        }
        tap(element, "\(name) in the menu", in: webView, file: file, line: line)
    }

    // An option of one of the page's <select>s, by the select's aria-label:
    // WebKit opens it as a menu on the iPhone, or as a wheel. The select is
    // an "Other" in the page's tree, its option the value.
    private func choose(_ option: String, in selectLabel: String, app: XCUIApplication,
                        file: StaticString = #filePath, line: UInt = #line) {
        let webView = app.webViews.firstMatch
        let select = text(selectLabel, in: webView)
        tap(select, "the \"\(selectLabel)\" filter", in: webView, file: file, line: line)

        let wheel = app.pickerWheels.firstMatch
        // Not a static text: a line of the page that reads the same would do.
        let item = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@ AND elementType IN %@", option,
                                  [XCUIElement.ElementType.menuItem, .button, .cell].map { NSNumber(value: $0.rawValue) }))
            .firstMatch
        guard waitForAny([wheel, item], timeout: 10) != nil else {
            debug("no-select-menu")
            return XCTFail("\"\(selectLabel)\" opened no menu with \(option)", file: file, line: line)
        }
        if wheel.exists {
            wheel.adjust(toPickerWheelValue: option)
            let done = app.toolbars.buttons.firstMatch
            if done.exists { done.tap() }
        } else {
            item.tap()
        }
        let chosen = waitUntil(timeout: 30) { (select.value as? String) == option }
        if !chosen { debug("not-chosen") }
        XCTAssertTrue(chosen, "\"\(selectLabel)\" did not change to \(option)", file: file, line: line)
    }

    private func backButton(_ app: XCUIApplication) -> XCUIElement {
        app.navigationBars.buttons.matching(NSPredicate(format: "identifier == 'BackButton'")).firstMatch
    }

    private func goBack(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let back = backButton(app)
        guard back.waitForExistence(timeout: 30) else {
            debug("no-back")
            return XCTFail("no Back button", file: file, line: line)
        }
        back.tap()
    }

    private func waitForAny(_ elements: [XCUIElement], timeout: TimeInterval) -> XCUIElement? {
        guard waitUntil(timeout: timeout, { elements.contains { $0.exists } }) else { return nil }
        return elements.first { $0.exists }
    }

    private func waitUntil(timeout: TimeInterval, _ condition: @escaping () -> Bool) -> Bool {
        let predicate = NSPredicate { _, _ in condition() }
        return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: nil)], timeout: timeout) == .completed
    }

    // Images, fonts and the map's tiles after the page itself; a scroll's
    // momentum.
    private func settle(_ seconds: TimeInterval) {
        _ = XCTWaiter().wait(for: [XCTestExpectation(description: "settle")], timeout: seconds)
    }

    // The whole screen, status bar included (the workflow sets it to 9:41),
    // at the phone's own pixels, redrawn opaque: App Store Connect refuses a
    // PNG with an alpha channel. The workflow keeps the "store-" ones.
    private func shot(_ name: String) {
        guard !onSignInForm else { return XCTFail("a store screenshot on the sign-in page") }
        guard let png = opaquePNG(XCUIScreen.main.screenshot().image) else {
            return XCTFail("could not redraw the \(name) screenshot")
        }
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: UTType.png.identifier)
        attachment.name = "store-\(language.code)-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // Into an RGB bitmap with no alpha (noneSkipLast), at the screenshot's
    // own pixels, then PNG.
    private func opaquePNG(_ image: UIImage) -> Data? {
        guard let source = image.cgImage,
              let context = CGContext(data: nil, width: source.width, height: source.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.draw(source, in: CGRect(x: 0, y: 0, width: source.width, height: source.height))
        guard let opaque = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, opaque, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    // What the app showed when something was missing, for the workflow's
    // debug artifact: never while the sign-in page is open.
    private func debug(_ name: String) {
        guard !onSignInForm else { return }
        let app = XCUIApplication()
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "debug-\(language.code)-\(name)"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "debug-\(language.code)-\(name)-hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
    }
}
