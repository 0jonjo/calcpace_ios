@testable import Calcpace
import XCTest

// The run's log on disk and its move to the outbox (RecorderFiles): a line
// synced per event, a torn last line never glued to the next, a stopped run
// saved once however often the save is retried. Android's RecorderFiles.
final class RecorderFilesTests: XCTestCase {
    private var root: URL!
    private let id = "0d9f3c2a-7b1e-4c5d-9e8f-1a2b3c4d5e6f"
    private let t0: Int64 = 1_760_000_000_000

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func fix(_ seconds: Int64, _ lat: Double) -> RunEvent {
        .fix(RunFix(time: t0 + seconds * 1000, lat: lat, lon: -35.2, altitude: 12.5, accuracy: 4))
    }

    func testEventsReadBackInOrder() throws {
        let files = RecorderFiles(root: root)
        let events: [RunEvent] = [
            .start(time: t0, recordingId: id, utcOffsetSeconds: -10800),
            fix(1, -5.8400), fix(2, -5.8401), .pause(time: t0 + 3000), .resume(time: t0 + 4000), .stop(time: t0 + 5000)
        ]
        try events.forEach(files.append)
        files.close()
        XCTAssertEqual(RecorderFiles(root: root).readCurrent(), events)
    }

    func testATornLastLineIsDroppedAndTheNextEventKept() throws {
        let files = RecorderFiles(root: root)
        try files.append(.start(time: t0, recordingId: id, utcOffsetSeconds: 0))
        files.close()
        let handle = try FileHandle(forWritingTo: files.current)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("F,17600000010".utf8))
        try handle.close()

        let reopened = RecorderFiles(root: root)
        try reopened.append(.pause(time: t0 + 2000))
        reopened.close()
        XCTAssertEqual(reopened.readCurrent(), [.start(time: t0, recordingId: id, utcOffsetSeconds: 0), .pause(time: t0 + 2000)])
    }

    func testFinishMovesTheRunToTheOutboxOnce() throws {
        let files = RecorderFiles(root: root)
        let events: [RunEvent] = [.start(time: t0, recordingId: id, utcOffsetSeconds: -10800), fix(1, -5.8400), fix(30, -5.8410), .stop(time: t0 + 31000)]
        try events.forEach(files.append)
        let track = Track(events)

        let entry = try files.finish(track, now: t0 + 40000)
        XCTAssertEqual(entry.recordingId, id)
        XCTAssertEqual(entry.utcOffsetSeconds, -10800)
        XCTAssertEqual(entry.movingMillis, 31000)
        XCTAssertFalse(files.hasCurrent)
        // Retried: the same folder, still one run.
        try files.finish(track, now: t0 + 50000)
        XCTAssertEqual(files.outbox.entries().map(\.recordingId), [id])
        let gpx = try String(contentsOf: files.outbox.gpx(id), encoding: .utf8)
        XCTAssertTrue(gpx.contains("utc_offset=\"-10800\""))
        XCTAssertEqual(gpx.components(separatedBy: "<trkpt ").count - 1, 2)
    }

    func testDiscardLeavesNothing() throws {
        let files = RecorderFiles(root: root)
        try files.append(.start(time: t0, recordingId: id, utcOffsetSeconds: 0))
        files.discard()
        XCTAssertFalse(files.hasCurrent)
        XCTAssertEqual(files.readCurrent(), [])
    }

    func testIdsAreLowercaseUuids() {
        XCTAssertTrue(RunLog.isRecordingId(RecorderFiles.newRecordingId()))
        XCTAssertTrue(RunLog.isRecordingId(RecorderFiles.recordingId(forStart: t0)))
        XCTAssertEqual(RecorderFiles.recordingId(forStart: t0), RecorderFiles.recordingId(forStart: t0))
    }

    func testTheFormHasTheFieldsAndTheFile() {
        let form = RecorderForm(fields: [("recording_uuid", id)], file: ("gpx", "run.gpx", "application/gpx+xml", Data("<gpx/>".utf8)))
        let body = String(decoding: form.body, as: UTF8.self)
        XCTAssertTrue(form.contentType.hasSuffix(form.boundary))
        XCTAssertTrue(body.contains("name=\"recording_uuid\"\r\n\r\n\(id)\r\n"))
        XCTAssertTrue(body.contains("name=\"gpx\"; filename=\"run.gpx\"\r\nContent-Type: application/gpx+xml\r\n\r\n<gpx/>\r\n"))
        XCTAssertTrue(body.hasSuffix("--\(form.boundary)--\r\n"))
    }
}
