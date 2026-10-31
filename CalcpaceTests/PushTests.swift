@testable import Calcpace
import UserNotifications
import XCTest

final class PushPayloadTests: XCTestCase {
    private let root = URL(string: "https://calcpace.app")!

    private func payload(title: Any? = "Your run is in", body: Any? = "10.2 km at 5:12/km", path: Any? = "/pt-BR/activities/123") -> [AnyHashable: Any] {
        var alert: [String: Any] = [:]
        alert["title"] = title
        alert["body"] = body
        var userInfo: [AnyHashable: Any] = ["aps": ["alert": alert, "sound": "default"] as [String: Any]]
        userInfo["path"] = path
        return userInfo
    }

    func testTheRunsPageOnTheSite() {
        XCTAssertEqual(PushPayload.parse(payload(), rootURL: root),
                       PushPayload.Notice(title: "Your run is in", body: "10.2 km at 5:12/km",
                                          url: URL(string: "https://calcpace.app/pt-BR/activities/123")!))
        XCTAssertEqual(PushPayload.parse(payload(path: "/activities/12?from=push#laps"), rootURL: root)?.url,
                       URL(string: "https://calcpace.app/activities/12?from=push#laps"))
        XCTAssertEqual(PushPayload.parse(payload(path: "/activities/12"), rootURL: URL(string: "https://calcpace.app/")!)?.url,
                       URL(string: "https://calcpace.app/activities/12"))
    }

    func testRefusesWhatTheServerDoesNotSend() {
        XCTAssertNil(PushPayload.parse(payload(path: nil), rootURL: root))
        XCTAssertNil(PushPayload.parse(payload(title: nil), rootURL: root))
        XCTAssertNil(PushPayload.parse(payload(body: nil), rootURL: root))
        XCTAssertNil(PushPayload.parse(payload(title: "  "), rootURL: root))
        XCTAssertNil(PushPayload.parse(payload(path: 12), rootURL: root))
        XCTAssertNil(PushPayload.parse(["aps": ["alert": "Your run is in"], "path": "/activities/1"], rootURL: root))
        XCTAssertNil(PushPayload.parse(["path": "/activities/1"], rootURL: root))
        XCTAssertNil(PushPayload.parse([:], rootURL: root))
    }

    func testOnlyAPlainPathOnTheSite() {
        for path in ["//evil.example/activities/1", "/\\evil.example", "\\evil.example", "https://evil.example/",
                     "javascript:alert(1)", "activities/1", "", "/activities/1 2", "/activities/1\n",
                     "/activities/\t1", "/activities/1\u{7F}", "/activities/1\u{0}", "@evil.example/x",
                     ".evil.example/x", ":8080/x"] {
            XCTAssertNil(PushPayload.parse(payload(path: path), rootURL: root), path.debugDescription)
        }
    }

    func testRefusesTooLong() {
        let fits = "/activities/1?" + String(repeating: "a", count: PushPayload.maxPath - 14)
        XCTAssertEqual(fits.utf16.count, PushPayload.maxPath)
        XCTAssertNotNil(PushPayload.parse(payload(path: fits), rootURL: root))
        XCTAssertNil(PushPayload.parse(payload(path: fits + "a"), rootURL: root))
    }
}

final class PushPagesTests: XCTestCase {
    private let root = URL(string: "https://calcpace.app")!

    func testTheHomePageInAnyLanguage() {
        for location in ["https://calcpace.app", "https://calcpace.app/", "https://calcpace.app/pt-BR",
                         "https://calcpace.app/zh-TW/", "https://calcpace.app/?ref=app", "https://calcpace.app/en#top"] {
            XCTAssertTrue(PushPages.isHome(URL(string: location), rootURL: root), location)
        }
    }

    func testNowhereElse() {
        for location in ["https://calcpace.app/activities", "https://calcpace.app/settings",
                         "https://calcpace.app/xx", "https://calcpace.app//", "https://calcpace.app/pt-BR/activities",
                         "https://calcpace.app.evil.example/", "https://evil.example/", "http://calcpace.app/",
                         "https://calcpace.app/%70t-BR"] {
            XCTAssertFalse(PushPages.isHome(URL(string: location), rootURL: root), location)
        }
        XCTAssertFalse(PushPages.isHome(nil, rootURL: root))
    }
}

final class PushStatusTests: XCTestCase {
    func testWhatThePageIsTold() {
        XCTAssertEqual(PushStatus.of(.authorized), "granted")
        XCTAssertEqual(PushStatus.of(.provisional), "granted")
        XCTAssertEqual(PushStatus.of(.ephemeral), "granted")
        XCTAssertEqual(PushStatus.of(.notDetermined), "default")
        XCTAssertEqual(PushStatus.of(.denied), "denied")
    }

    func testTheTokenInLowercaseHex() {
        XCTAssertEqual(PushToken.hex(Data([0x00, 0x0F, 0xA0, 0xFF, 0x12])), "000fa0ff12")
        XCTAssertEqual(PushToken.hex(Data(repeating: 0xAB, count: 32)), String(repeating: "ab", count: 32))
        XCTAssertEqual(PushToken.hex(Data()), "")
    }
}

@MainActor
final class PushRegistrationTests: XCTestCase {
    func testOneRegistrationAnswersEverybodyWaiting() {
        var registrations = 0
        let registration = PushRegistration(register: { registrations += 1 })
        var answers: [String?] = []

        registration.token { answers.append($0) }
        registration.token { answers.append($0) }
        XCTAssertEqual(registrations, 1)

        registration.didRegister(Data([0xCA, 0xFE]))
        XCTAssertEqual(answers, ["cafe", "cafe"])

        // Answered: the next one asks iOS again.
        registration.token { answers.append($0) }
        XCTAssertEqual(registrations, 2)
    }

    func testAFailureAnswersWithoutAToken() {
        let registration = PushRegistration(register: {})
        var answers: [String?] = []

        registration.token { answers.append($0) }
        registration.didFail()
        XCTAssertEqual(answers, [nil])

        // Nobody waiting: a late token goes nowhere.
        registration.didRegister(Data([0x01]))
        XCTAssertEqual(answers, [nil])
    }

    func testGivesUpWhenIOSNeverAnswers() {
        let registration = PushRegistration(timeout: 0.1, register: {})
        let answered = expectation(description: "answered")
        var answers: [String?] = []

        registration.token {
            answers.append($0)
            answered.fulfill()
        }
        wait(for: [answered], timeout: 5)
        XCTAssertEqual(answers, [nil])
    }
}

@MainActor
final class PushInboxTests: XCTestCase {
    private let run = URL(string: "https://calcpace.app/activities/1")!
    private let other = URL(string: "https://calcpace.app/activities/2")!

    func testATapBeforeTheNavigatorWaitsForIt() {
        let inbox = PushInbox()
        var routed: [URL] = []

        inbox.open(other)
        inbox.open(run)
        XCTAssertEqual(routed, [])

        inbox.ready { routed.append($0) }
        XCTAssertEqual(routed, [run])
    }

    func testATapAfterGoesStraightThrough() {
        let inbox = PushInbox()
        var routed: [URL] = []

        inbox.ready { routed.append($0) }
        XCTAssertEqual(routed, [])

        inbox.open(run)
        inbox.open(other)
        XCTAssertEqual(routed, [run, other])
    }
}
