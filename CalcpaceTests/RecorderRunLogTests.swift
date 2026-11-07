@testable import Calcpace
import XCTest

// The Android app's cases (RunLogTest.kt, the log part), on the same format:
// a log written by either phone reads the same.
final class RecorderRunLogTests: XCTestCase {
    private let t: Int64 = 1_760_000_000_000
    private let id = "3f2504e0-4f89-41d3-9a0c-0305e82c3301"

    private func fix(_ time: Int64, _ lat: Double, _ lon: Double, _ altitude: Double?, _ accuracy: Double) -> RunEvent {
        .fix(RunFix(time: time, lat: lat, lon: lon, altitude: altitude, accuracy: accuracy))
    }

    func testEveryEventSurvivesTheRoundTrip() {
        let events: [RunEvent] = [
            .start(time: t + 1000, recordingId: id, utcOffsetSeconds: -10_800),
            fix(t + 2000, -5.8400001, -35.2000002, 31.5, 4.5),
            fix(t + 3000, 51.5, -0.1, nil, 12),
            .pause(time: t + 4000),
            .resume(time: t + 5000),
            .stop(time: t + 6000),
        ]

        XCTAssertEqual(RunLog.parse(events.map(RunLog.line).joined(separator: "\n")), events)
    }

    // The process was killed in the middle of a write.
    func testACutOffLastLineIsSkipped() {
        let text = "S,\(t + 1000)\nF,\(t + 2000),-5.84,-35.2,,5.0\nF,\(t + 3000),-5.8"
        XCTAssertEqual(
            RunLog.parse(text),
            [.start(time: t + 1000, recordingId: nil, utcOffsetSeconds: nil), fix(t + 2000, -5.84, -35.2, nil, 5)]
        )
    }

    // An Android log recorded before runs had an id still reads.
    func testAStartWithoutAnIdStillReads() {
        XCTAssertEqual(RunLog.parseLine("S,\(t)"), .start(time: t, recordingId: nil, utcOffsetSeconds: nil))
        XCTAssertEqual(RunLog.parseLine("S2,\(t),-10800,\(id)"), .start(time: t, recordingId: id, utcOffsetSeconds: -10_800))
        XCTAssertEqual(RunLog.line(.start(time: t, recordingId: nil, utcOffsetSeconds: nil)), "S,\(t)")
    }

    // Each of these is a whole line cut short: none may read as a different event.
    func testATornLastFieldNeverReadsAsAnotherValue() {
        let start = "S2,\(t),-10800,\(id)"
        let fixLine = "F,\(t),-5.8400000,-35.2000000,31.5,30.0"
        for length in 1 ..< start.count {
            let torn = String(start.prefix(length))
            XCTAssertNil(RunLog.parseLine(torn), torn)
        }
        // "F,…,3" is the 30.0 m fix cut down to a 3 m one; "F,…,30." keeps
        // the value but not the writer's shape.
        for length in 1 ..< fixLine.count {
            let torn = String(fixLine.prefix(length))
            XCTAssertNil(RunLog.parseLine(torn), torn)
        }
        XCTAssertEqual(RunLog.parseLine(fixLine), fix(t, -5.84, -35.2, 31.5, 30))
    }

    func testLinesThatDoNotHoldUpAreSkipped() {
        let lines = [
            "", "X,\(t)", "S", "S,abc", "S,\(t),2", "S,17", "R,1760000", "F,1700,0,0,,5",
            "F,\(t),91,0,,5.0", "F,\(t),0,181,,5.0", "F,\(t),0,0,x,5.0", "F,\(t),0,0,,", "F,\(t),0,0,,5.0,9",
            "F,\(t),0,0,,5", "F,\(t),0,0,,5.00", "F,\(t),0,0,,-5.0",
            "S,\(t),-10800,\(id)", "S2,\(t)", "S2,\(t),-10800", "S2,\(t),x,\(id)", "S2,\(t),99999,\(id)",
            "S2,\(t),-10800,not-an-id", "S2,\(t),-10800,\(id.uppercased())",
        ]
        for line in lines {
            XCTAssertNil(RunLog.parseLine(line), line)
        }
    }

    // A phone in German would write 10,5 for 10.5 if the number followed the
    // language, and the comma is the field separator. Android sets the default
    // locale to Germany for this; String(format:) without a locale is never
    // localized, so the line is the same on any phone.
    func testFixesAreWrittenWithDotsWhateverTheLocale() {
        XCTAssertEqual(RunLog.line(fix(t, -5.84, -35.2, 10.5, 3.5)), "F,\(t),-5.8400000,-35.2000000,10.5,3.5")
    }
}
