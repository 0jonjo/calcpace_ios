@testable import Calcpace
import XCTest

// The Android app's cases (OutboxTest.kt), on the same rules. The ids are
// UUIDs here, as the iOS outbox only names a folder after one, and the meta
// is JSON (run.json).
final class RecorderOutboxTests: XCTestCase {
    private var root: URL!
    private var outbox: Outbox!
    private let files = FileManager.default

    private let a = "00000000-0000-4000-8000-00000000000a"
    private let b = "00000000-0000-4000-8000-00000000000b"
    private let c = "00000000-0000-4000-8000-00000000000c"

    override func setUpWithError() throws {
        root = files.temporaryDirectory.appendingPathComponent("outbox-\(UUID().uuidString)", isDirectory: true)
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        outbox = Outbox(root: root.appendingPathComponent("outbox", isDirectory: true))
    }

    override func tearDownWithError() throws {
        try? files.removeItem(at: root)
    }

    private func entry(_ id: String, startedAt: Int64 = 1_760_000_000_000) -> Outbox.Entry {
        Outbox.Entry(
            recordingId: id, startedAt: startedAt, utcOffsetSeconds: -10_800, distanceMeters: 5_210.4,
            movingMillis: 1_902_000, filename: "calcpace-2025-10-09-055320.gpx"
        )
    }

    private func path(_ id: String, _ name: String? = nil) -> URL {
        let dir = root.appendingPathComponent("outbox/\(id)", isDirectory: true)
        return name.map { dir.appendingPathComponent($0) } ?? dir
    }

    private func text(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    func testARunGoesInWithItsFileAndLogAndComesBackTheSame() throws {
        let log = root.appendingPathComponent("current.log")
        try Data("S,1\n".utf8).write(to: log)
        try outbox.add(entry(a), gpx: "<gpx/>", log: log)

        XCTAssertEqual(outbox.entries(), [entry(a)])
        XCTAssertEqual(try text(outbox.gpx(a)), "<gpx/>")
        XCTAssertEqual(try text(path(a, Outbox.logName)), "S,1\n")
    }

    func testRunsAreListedOldestFirst() throws {
        try outbox.add(entry(c, startedAt: 3), gpx: "<gpx/>", log: nil)
        try outbox.add(entry(a, startedAt: 1), gpx: "<gpx/>", log: nil)
        try outbox.add(entry(b, startedAt: 2), gpx: "<gpx/>", log: nil)

        XCTAssertEqual(outbox.entries().map(\.recordingId), [a, b, c])
    }

    // A save cut short and done again: still one run.
    func testSavingTheSameRecordingAgainReplacesIt() throws {
        try outbox.add(entry(a), gpx: "<gpx>1</gpx>", log: nil)
        let again = Outbox.Entry(
            recordingId: a, startedAt: 1_760_000_000_000, utcOffsetSeconds: -10_800, distanceMeters: 10,
            movingMillis: 1_902_000, filename: "calcpace-2025-10-09-055320.gpx"
        )
        try outbox.add(again, gpx: "<gpx>2</gpx>", log: nil)

        XCTAssertEqual(outbox.entries().map(\.distanceMeters), [10])
        XCTAssertEqual(try text(outbox.gpx(a)), "<gpx>2</gpx>")
    }

    func testTheStateOfAnUploadIsKept() throws {
        try outbox.add(entry(a), gpx: "<gpx/>", log: nil)
        var signedOut = entry(a)
        signedOut.state = .signedOut
        signedOut.lastAttemptAt = 42
        outbox.update(signedOut)

        XCTAssertEqual(outbox.entry(a)?.state, .signedOut)
        XCTAssertEqual(outbox.entry(a)?.lastAttemptAt, 42)
    }

    // The upload updating a run another one has just sent and removed.
    func testUpdatingARunAlreadyGoneBringsNothingBack() {
        var gone = entry(a)
        gone.state = .refused
        outbox.update(gone)

        XCTAssertTrue(outbox.entries().isEmpty)
        XCTAssertFalse(files.fileExists(atPath: path(a).path))
    }

    func testARemovedRunIsGoneWithItsFiles() throws {
        try outbox.add(entry(a), gpx: "<gpx/>", log: nil)
        outbox.remove(a)

        XCTAssertTrue(outbox.entries().isEmpty)
        XCTAssertFalse(files.fileExists(atPath: path(a).path))
    }

    // Killed between the GPX and the description: the log it came from is
    // still there, and the next save writes the folder again.
    func testAFolderCutShortIsNotARun() throws {
        try files.createDirectory(at: path(a), withIntermediateDirectories: true)
        try Data("<gpx/>".utf8).write(to: path(a, Outbox.gpxName))
        try files.createDirectory(at: path(b), withIntermediateDirectories: true)
        try Data("recording_id=\(b)\n".utf8).write(to: path(b, Outbox.metaName))

        XCTAssertTrue(outbox.entries().isEmpty)
        XCTAssertNil(outbox.entry(a))
    }

    // A description copied into another run's folder must not send that
    // run's file under this id.
    func testADescriptionOfAnotherRunIsNotThisRun() throws {
        try outbox.add(entry(a), gpx: "<gpx/>", log: nil)
        try files.createDirectory(at: path(b), withIntermediateDirectories: true)
        try files.copyItem(at: path(a, Outbox.gpxName), to: path(b, Outbox.gpxName))
        try files.copyItem(at: path(a, Outbox.metaName), to: path(b, Outbox.metaName))

        XCTAssertEqual(outbox.entries().map(\.recordingId), [a])
    }

    func testNoTemporaryFilesAreLeftBehind() throws {
        try outbox.add(entry(a), gpx: "<gpx/>", log: root.appendingPathComponent("missing.log"))
        var refused = entry(a)
        refused.state = .refused
        outbox.update(refused)

        XCTAssertEqual(Set(try files.contentsOfDirectory(atPath: path(a).path)), [Outbox.gpxName, Outbox.metaName])
    }
}
