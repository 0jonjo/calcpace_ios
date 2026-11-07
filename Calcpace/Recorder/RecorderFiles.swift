import Foundation

/// Where a run lives on the phone. While it is on: `recorder/current.log`
/// under Application Support (the `RunLog`, appended and synced line by
/// line). Once stopped, the GPX and the log go to the `outbox`, where they
/// wait for the site's OK; nothing is copied anywhere else, so the route
/// stays in the app. The Android app's RecorderFiles.kt.
///
/// Files keep iOS's default protection (complete until first unlock), so a
/// run writes on with the phone locked in a pocket.
final class RecorderFiles {
    let dir: URL
    let current: URL
    let outbox: Outbox

    private var handle: FileHandle?

    init(root: URL = RecorderFiles.defaultRoot) {
        dir = root.appendingPathComponent("recorder", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        current = dir.appendingPathComponent("current.log")
        outbox = Outbox(root: dir.appendingPathComponent("outbox", isDirectory: true))
    }

    static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    var hasCurrent: Bool { FileManager.default.fileExists(atPath: current.path) }

    func readCurrent() -> [RunEvent] {
        guard let data = try? Data(contentsOf: current) else { return [] }
        return RunLog.parse(String(decoding: data, as: UTF8.self))
    }

    /// One line, on disk before this returns: a kill a moment later loses
    /// nothing. Throws when it can't be written (a full disk): the caller
    /// decides what the run does then.
    func append(_ event: RunEvent) throws {
        let handle = try self.handle ?? open()
        do {
            try handle.write(contentsOf: Data((RunLog.line(event) + "\n").utf8))
            try handle.synchronize()
        } catch {
            // Half a line may be on disk: the next open starts a fresh one.
            close()
            throw error
        }
    }

    func close() {
        try? handle?.close()
        handle = nil
    }

    /// Puts the stopped run in the `outbox` and starts a clean log. The log
    /// goes only once the outbox has the run: if writing fails, current.log
    /// keeps the stopped run and the next Start saves it before beginning
    /// another. Saving the same run twice lands in the same outbox folder (its
    /// recording id), so a save cut short and retried is still one run.
    /// Returns the run's recording id.
    @discardableResult
    func finish(_ track: Track, now: Int64) throws -> Outbox.Entry {
        close()
        let start = track.startedAt ?? now
        let id = track.recordingId ?? Self.recordingId(forStart: start)
        let entry = Outbox.Entry(
            recordingId: id,
            startedAt: start,
            utcOffsetSeconds: track.utcOffsetSeconds ?? Self.offset(at: start),
            distanceMeters: track.distanceMeters,
            movingMillis: track.movingMillis(track.stoppedAt ?? start),
            filename: Gpx.filename(start)
        )
        try outbox.add(entry, gpx: Gpx.write(track, name: "Run"), log: current)
        // Left in place, the old log would take the next run's events after its Stop.
        if hasCurrent { try FileManager.default.removeItem(at: current) }
        return entry
    }

    /// Throws the run away: its log, nothing kept.
    func discard() {
        close()
        try? FileManager.default.removeItem(at: current)
    }

    /// A new run's id: a lowercase UUID, the shape the log and the site expect.
    static func newRecordingId() -> String {
        UUID().uuidString.lowercased()
    }

    /// An id for a log with none (an old Android log moved over, never one
    /// this app wrote): made from its start, so every retry gives the same.
    static func recordingId(forStart start: Int64) -> String {
        let hex = String(format: "%012llx", UInt64(max(start, 0)) & 0xFFFF_FFFF_FFFF)
        return "00000000-0000-4000-8000-" + hex
    }

    static func offset(at epochMillis: Int64, timeZone: TimeZone = .current) -> Int {
        timeZone.secondsFromGMT(for: Gpx.date(epochMillis))
    }

    // MARK: Private

    // A power cut can leave the last line half written. The next event must
    // start a line of its own, or it would be glued to the torn one and lost
    // with it on the next read.
    private func open() throws -> FileHandle {
        if !hasCurrent {
            guard FileManager.default.createFile(atPath: current.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        let handle = try FileHandle(forWritingTo: current)
        do {
            let end = try handle.seekToEnd()
            if end > 0, let last = try? Data(contentsOf: current).last, last != UInt8(ascii: "\n") {
                try handle.write(contentsOf: Data("\n".utf8))
            }
        } catch {
            try? handle.close()
            throw error
        }
        self.handle = handle
        return handle
    }
}
