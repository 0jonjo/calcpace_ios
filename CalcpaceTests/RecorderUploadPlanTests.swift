@testable import Calcpace
import XCTest

// The Android app's cases (UploadPlanTest.kt), on the same rules: each answer
// of the site's POST /recordings means the same on both phones.
final class RecorderUploadPlanTests: XCTestCase {
    func testEachAnswerOfTheSiteMeansOneThing() {
        let plan: [(Int, UploadPlan.Outcome)] = [
            (201, .done),
            (200, .done),
            (401, .signedOut),
            (409, .noProfile),
            (422, .refused),
            // The app's header missing, or a challenge in between: not the file's fault.
            (403, .retry),
            (413, .refused),
            (400, .refused),
            // A site without the endpoint yet, a slow link, too many at once.
            (404, .retry),
            (408, .retry),
            (429, .retry),
            (500, .retry),
            (503, .retry),
            // A redirect is never the endpoint's: something in between.
            (302, .retry),
            (UploadPlan.noAnswer, .retry),
        ]
        for (code, outcome) in plan {
            XCTAssertEqual(UploadPlan.outcome(code), outcome, "\(code)")
        }
    }

    func testTheAnswerNamesTheRunAndItsEditPage() {
        XCTAssertEqual(
            UploadPlan.answer(Data(#"{"id":42,"edit_url":"https://calcpace.app/pt-BR/activities/42/edit?via=recorder"}"#.utf8)),
            UploadPlan.Answer(id: 42, editURL: "https://calcpace.app/pt-BR/activities/42/edit?via=recorder")
        )
        for body in ["", "<html>", "[]", #"{"id":42}"#, #"{"id":"x","edit_url":"u"}"#, #"{"id":42,"edit_url":7}"#] {
            XCTAssertNil(UploadPlan.answer(Data(body.utf8)), body)
        }
    }

    func testTheStartGoesWithThePhonesOffset() {
        let start: Int64 = 1_760_000_000_123 // 2025-10-09T08:53:20.123Z
        XCTAssertEqual(UploadPlan.startedAt(start, utcOffsetSeconds: -10_800), "2025-10-09T05:53:20-03:00")
        XCTAssertEqual(UploadPlan.startedAt(start, utcOffsetSeconds: 0), "2025-10-09T08:53:20Z")
        XCTAssertEqual(UploadPlan.startedAt(start, utcOffsetSeconds: 19_800), "2025-10-09T14:23:20+05:30")
    }

    func testTheScreenSaysWhereTheUploadStands() {
        XCTAssertEqual(UploadPlan.card(.pending, sending: true, online: true, attempted: true), .sending)
        XCTAssertEqual(UploadPlan.card(.pending, sending: false, online: true, attempted: false), .sending)
        XCTAssertEqual(UploadPlan.card(.pending, sending: false, online: false, attempted: true), .queued)
        XCTAssertEqual(UploadPlan.card(.pending, sending: false, online: true, attempted: true), .failed)
        XCTAssertEqual(UploadPlan.card(.signedOut, sending: false, online: false, attempted: true), .signedOut)
        XCTAssertEqual(UploadPlan.card(.noProfile, sending: false, online: true, attempted: true), .noProfile)
        XCTAssertEqual(UploadPlan.card(.refused, sending: false, online: true, attempted: true), .refused)
    }
}
