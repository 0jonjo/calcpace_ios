import XCTest

// The run recorder without the site: the app's harness (RecorderHarness,
// debug builds only) opens the recording screen with a fake server behind
// it. The CI job's relay (ci.yml) moves the simulator along a straight
// 600 m line at 5 m/s when this test asks (location.route in PUSH_DIR), so
// the real Core Location path is what records. Start, run past 100 m and a
// minute, Pause, Finish, Save: the run goes up and its edit page opens.
final class RecorderTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testRecordsARunAndOpensItsPage() throws {
        guard let path = ProcessInfo.processInfo.environment["PUSH_DIR"], !path.isEmpty else {
            throw XCTSkip("no relay (PUSH_DIR): CI's test step runs one")
        }
        let relay = URL(fileURLWithPath: path)

        let app = XCUIApplication()
        app.launchArguments = ["-recorderHarness"]
        app.launch()

        let primary = app.buttons["recorder.primary"]
        XCTAssertTrue(primary.waitForExistence(timeout: 20), "no recording screen")
        attachScreenshot(of: app, named: "recorder-ready")

        // 600 m northwards, in Lisbon: a waypoint starting with "-" would
        // read as an option to simctl.
        try "38.7000,-9.1400 38.7054,-9.1400".write(to: relay.appendingPathComponent("location.route"), atomically: true, encoding: .utf8)
        primary.tap()
        allowLocation(in: app)

        let distance = app.staticTexts["recorder.distance"]
        let farEnough = NSPredicate { object, _ in
            guard let label = (object as? XCUIElement)?.label, let value = Double(label.split(separator: " ").first ?? "") else { return false }
            return value >= 0.30
        }
        wait(for: [XCTNSPredicateExpectation(predicate: farEnough, object: distance)], timeout: 150)
        // Past the minute a run needs to be saved.
        let clock = app.staticTexts["recorder.clock"]
        let longEnough = NSPredicate { object, _ in
            guard let label = (object as? XCUIElement)?.label else { return false }
            let seconds = label.split(separator: ":").compactMap { Int($0) }.reduce(0) { $0 * 60 + $1 }
            return seconds >= 65
        }
        wait(for: [XCTNSPredicateExpectation(predicate: longEnough, object: clock)], timeout: 90)
        attachScreenshot(of: app, named: "recorder-running")

        primary.tap()
        let finish = app.buttons["recorder.finish"]
        XCTAssertTrue(finish.waitForExistence(timeout: 5), "no Finish after Pause")
        attachScreenshot(of: app, named: "recorder-paused")
        finish.tap()

        let save = app.alerts.buttons["Save run"]
        XCTAssertTrue(save.waitForExistence(timeout: 5), "no Save in the confirmation")
        attachScreenshot(of: app, named: "recorder-finish")
        save.tap()

        let status = app.staticTexts["harness.status"]
        let opened = NSPredicate(format: "label BEGINSWITH 'opened'")
        wait(for: [XCTNSPredicateExpectation(predicate: opened, object: status)], timeout: 60)
        attachScreenshot(of: app, named: "recorder-uploaded")

        let words = status.label.split(separator: " ").map(String.init)
        XCTAssertEqual(words.dropFirst().first, "/activities/42/edit", status.label)
        XCTAssertTrue(words.contains("path=/recordings"), status.label)
        XCTAssertTrue(words.contains("uuid=ok"), status.label)
        XCTAssertTrue(words.contains("start=ok"), status.label)
        XCTAssertTrue(words.contains("header=true"), status.label)
        XCTAssertTrue(words.contains("cookie=true"), status.label)
        XCTAssertTrue(words.contains("creator=true"), status.label)
        let points = words.first { $0.hasPrefix("points=") }.flatMap { Int($0.dropFirst(7)) } ?? 0
        XCTAssertGreaterThan(points, 30, status.label)
    }

    // The location sheet, drawn by SpringBoard. A simulator that answered it
    // on an earlier run shows none.
    private func allowLocation(in app: XCUIApplication) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.buttons["Allow While Using App"]
        if allow.waitForExistence(timeout: 10) {
            allow.tap()
            // The tap on Start waited for the answer, and starts the run now.
        }
        let status = app.staticTexts["recorder.status"]
        let recording = NSPredicate(format: "label BEGINSWITH 'Recording'")
        wait(for: [XCTNSPredicateExpectation(predicate: recording, object: status)], timeout: 20)
    }

    private func attachScreenshot(of app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
