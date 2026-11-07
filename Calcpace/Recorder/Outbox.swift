import Foundation

/// The finished runs still on the phone, waiting for the site's OK: one
/// folder per run under `Application Support/recorder/outbox/`, named by its
/// recording id, holding the GPX (`gpxName`), the raw `RunLog` (`logName`) and
/// what the screen and the upload need without reading either (`metaName`).
/// The Android app's Outbox.kt.
///
/// A run leaves only on `remove`, which the upload calls after a 2xx. Saving
/// the same recording again (a save cut short and retried) lands in the same
/// folder: one run, never two. A folder whose meta is missing was cut short
/// before it was complete and is not listed; the log it came from is still
/// there, and the next save writes it again.
final class Outbox {
    enum State: String, Codable {
        /// Goes up with the next upload.
        case pending = "PENDING"
        /// The site said signed out (401): waits for the app to be opened.
        case signedOut = "SIGNED_OUT"
        /// Signed in, but the account has no profile yet (409).
        case noProfile = "NO_PROFILE"
        /// The site will never take this file (422 and the like): kept to be shared by hand.
        case refused = "REFUSED"
    }

    struct Entry: Codable, Equatable {
        let recordingId: String
        let startedAt: Int64
        let utcOffsetSeconds: Int
        let distanceMeters: Double
        let movingMillis: Int64
        let filename: String
        var state: State = .pending
        var lastAttemptAt: Int64?

        enum CodingKeys: String, CodingKey {
            case recordingId = "recording_id"
            case startedAt = "started_at"
            case utcOffsetSeconds = "utc_offset"
            case distanceMeters = "distance_m"
            case movingMillis = "moving_ms"
            case filename
            case state
            case lastAttemptAt = "last_attempt_at"
        }
    }

    static let gpxName = "run.gpx"
    static let logName = "run.log"
    static let metaName = "run.json"

    private let root: URL
    private let files = FileManager.default

    init(root: URL) {
        self.root = root
    }

    /// Writes the run's folder, the meta last: until it is there the run is not in the outbox.
    func add(_ entry: Entry, gpx: String, log: URL?) throws {
        let dir = folder(entry.recordingId)
        try files.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(gpx.utf8).write(to: dir.appendingPathComponent(Self.gpxName), options: .atomic)
        if let log, let bytes = try? Data(contentsOf: log) {
            try bytes.write(to: dir.appendingPathComponent(Self.logName), options: .atomic)
        }
        try write(entry)
    }

    func entries() -> [Entry] {
        let dirs = (try? files.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return dirs.compactMap(read).sorted { $0.startedAt < $1.startedAt }
    }

    func entry(_ recordingId: String) -> Entry? {
        read(folder(recordingId))
    }

    func gpx(_ recordingId: String) -> URL {
        folder(recordingId).appendingPathComponent(Self.gpxName)
    }

    /// Saves `entry`'s state; a no-op for a run already gone (sent meanwhile).
    func update(_ entry: Entry) {
        var isDirectory: ObjCBool = false
        guard files.fileExists(atPath: folder(entry.recordingId).path, isDirectory: &isDirectory), isDirectory.boolValue else { return }
        try? write(entry)
    }

    func remove(_ recordingId: String) {
        try? files.removeItem(at: folder(recordingId))
    }

    // MARK: Private

    // Only ids of the UUID shape name a folder: nothing read back can point
    // outside the outbox.
    private func folder(_ recordingId: String) -> URL {
        root.appendingPathComponent(RunLog.isRecordingId(recordingId) ? recordingId : "invalid", isDirectory: true)
    }

    private func write(_ entry: Entry) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        // Atomic: a power cut mid-write leaves the old file or none, never half of one.
        try encoder.encode(entry).write(to: folder(entry.recordingId).appendingPathComponent(Self.metaName), options: .atomic)
    }

    private func read(_ dir: URL) -> Entry? {
        guard RunLog.isRecordingId(dir.lastPathComponent),
              files.fileExists(atPath: dir.appendingPathComponent(Self.gpxName).path),
              let data = try? Data(contentsOf: dir.appendingPathComponent(Self.metaName)),
              let entry = try? JSONDecoder().decode(Entry.self, from: data),
              entry.recordingId == dir.lastPathComponent
        else { return nil }
        return entry
    }
}
