import XCTest

// Apple Health without the site: the app's harness (HealthHarness, debug
// builds only) writes five workouts to the simulator's Apple Health, links
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
    }

    // HealthKit's sheet, drawn inside the app: turn every type on, then
    // allow. Its labels are the simulator's English. A simulator that
    // answered it on an earlier run shows none, and the harness goes on.
    private func allowHealthAccess(in app: XCUIApplication) {
        let turnOnAll = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH 'Turn On All'")).firstMatch
        guard turnOnAll.waitForExistence(timeout: 120) else {
            attachScreenshot(of: app, named: "no-health-sheet")
            return
        }
        attachScreenshot(of: app, named: "health-sheet")
        turnOnAll.tap()

        let allow = app.buttons["Allow"].firstMatch
        XCTAssertTrue(allow.waitForExistence(timeout: 10), "no Allow button")
        allow.tap()
    }

    private func attachScreenshot(of app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
