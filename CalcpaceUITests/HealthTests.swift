import XCTest

// Apple Health without the site: the app's harness (HealthHarness, debug
// builds only) writes eight workouts to the simulator's Apple Health, links
// with a made-up token and syncs against a fake server in its own process.
// This test answers the HealthKit sheet and reads what the harness saw.
final class HealthTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testSendsRunsAndWalksFromAppleHealth() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-healthHarness"]
        app.launch()

        allowHealthAccess(in: app)

        let status = app.staticTexts["harness.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 10), "no harness")
        let finished = NSPredicate(format: "label BEGINSWITH 'done' OR label BEGINSWITH 'error'")
        wait(for: [XCTNSPredicateExpectation(predicate: finished, object: status)], timeout: 180)
        attachScreenshot(of: app, named: "health-harness")

        let words = status.label.split(separator: " ").map(String.init)
        XCTAssertEqual(words.first, "done", status.label)
        // The ride is no run: three sessions, each with its type.
        XCTAssertTrue(words.contains("sent=running,running_treadmill,walking"), status.label)
        XCTAssertTrue(words.contains("initial=true"), status.label)
        // Heart rate samples of 150 and 160 during the run.
        XCTAssertTrue(words.contains { $0.hasPrefix("hr=15") && $0.hasSuffix("/160") }, status.label)
        XCTAssertTrue(words.contains("zone=-10800"), status.label)
        // A location a second for 25 minutes, a point every 5 seconds sent,
        // each [epoch seconds, lat, lon].
        XCTAssertTrue(words.contains("route=301/true"), status.label)
        // Saved after the sync that sent them: the walk's route (24
        // minutes), the run's distance; each once, and nothing on a sync
        // with nothing new.
        XCTAssertTrue(words.contains("lateroute=289"), status.label)
        XCTAssertTrue(words.contains("latedistance=4000"), status.label)
        XCTAssertTrue(words.contains("later=2"), status.label)
        XCTAssertTrue(words.contains("quiet=true"), status.label)
        XCTAssertTrue(words.contains("deleted=true"), status.label)
        XCTAssertTrue(words.contains("unlinked=true"), status.label)
        XCTAssertTrue(words.contains("bearer=true"), status.label)
        // Before the 30 days: the run of 41 days ago, not the walk, nor the
        // run of four years ago; as initial, so no notification.
        XCTAssertTrue(words.contains("history=100"), status.label)
        XCTAssertTrue(words.contains("historyinitial=true"), status.label)
    }

    // HealthKit's sheet, drawn inside the app: turn every type on, then
    // allow. Its labels are the simulator's English: "Turn On All" up to
    // iOS 26, "Select All 8 Topics" from iOS 27. A simulator that answered
    // it on an earlier run shows none, and the harness goes on.
    private func allowHealthAccess(in app: XCUIApplication) {
        let turnOnAll = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH 'Turn On All' OR label BEGINSWITH 'Select All'")).firstMatch
        guard turnOnAll.waitForExistence(timeout: 120) else {
            attachScreenshot(of: app, named: "no-health-sheet")
            return
        }
        attachScreenshot(of: app, named: "health-sheet")
        turnOnAll.tap()

        // Up to iOS 26, Allow is a button in the navigation bar. From iOS 27
        // it is a button at the end of the list, below the screen, which
        // reads "Continue" once every topic is on; off screen it shows only
        // as an "Allow" text, so it is scrolled to and tapped by identifier.
        let barButton = app.buttons["Allow"].firstMatch
        let row = app.staticTexts.matching(NSPredicate(format: "label == 'Allow'")).firstMatch
        let either = NSPredicate { _, _ in barButton.exists || row.exists }
        wait(for: [XCTNSPredicateExpectation(predicate: either, object: nil)], timeout: 10)
        if barButton.exists {
            barButton.tap()
            return
        }
        let listButton = app.buttons["UIA.Health.Allow.Button"].firstMatch
        for _ in 0..<8 where !(listButton.exists && listButton.isHittable) { app.swipeUp() }
        XCTAssertTrue(listButton.exists && listButton.isHittable, "no Allow button")
        listButton.tap()

        // iOS 27 then asks how far back to share, with Allow off until one
        // is picked. The harness reads a run of 41 days ago, so all recorded
        // data; on a small phone the floating buttons cover that option
        // until the page is scrolled.
        let allData = app.staticTexts["All Recorded Data and Future Data"].firstMatch
        XCTAssertTrue(allData.waitForExistence(timeout: 10), "no how-far-back page")
        attachScreenshot(of: app, named: "health-history")
        app.swipeUp()
        app.swipeUp()
        // A tap while the page still glides only stops it, so the option is
        // tapped again until Allow turns on.
        // This page's Allow has no identifier, only its label.
        let allow = app.buttons.matching(NSPredicate(format: "label == 'Allow'")).firstMatch
        XCTAssertTrue(allow.waitForExistence(timeout: 5), "no Allow on the how-far-back page")
        for _ in 0..<3 where !allow.isEnabled {
            allData.tap()
            let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: allow)
            _ = XCTWaiter.wait(for: [enabled], timeout: 3)
        }
        XCTAssertTrue(allow.isEnabled, "Allow stays off after picking all recorded data")
        allow.tap()
    }

    private func attachScreenshot(of app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
