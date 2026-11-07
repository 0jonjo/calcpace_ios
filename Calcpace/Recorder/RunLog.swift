import Foundation

/// A GPS position the recorder got, in epoch milliseconds like every time in
/// the run's log.
struct RunFix: Equatable {
    let time: Int64
    let lat: Double
    let lon: Double
    /// Metres above sea level, or nil when the GPS gave no altitude.
    let altitude: Double?
    /// Metres, the radius the position is good to.
    let accuracy: Double
}

/// What happens during a run, in the order it happens: the same events drive
/// the screen live and, after the app was killed, rebuild the run from the
/// log (`Track`).
enum RunEvent: Equatable {
    /// Start, with the id the server knows the run by (a UUID, so a retried
    /// upload is never a second run) and the phone's offset from UTC at that
    /// instant (-10800 in Brazil).
    case start(time: Int64, recordingId: String?, utcOffsetSeconds: Int?)
    case pause(time: Int64)
    case resume(time: Int64)
    case stop(time: Int64)
    case fix(RunFix)

    var time: Int64 {
        switch self {
        case let .start(time, _, _), let .pause(time), let .resume(time), let .stop(time): return time
        case let .fix(fix): return fix.time
        }
    }
}

/// What the recorder writes down while a run is on, one line per event,
/// appended and synced as it happens (`RecorderFiles`): if the app is killed
/// mid-run, the file holds everything up to the last fix and the run can be
/// finished from it. The Android app's format (RunLog.kt), line for line:
///
/// - `S2,<ms>,<utc offset s>,<recording id>` start. Android's older
///   `S,<ms>` (no id, no offset) still reads;
/// - `P,<ms>` pause, `R,<ms>` resume, `E,<ms>` stop;
/// - `F,<ms>,<lat>,<lon>,<altitude or empty>,<accuracy m>` a GPS fix.
///
/// A line that does not parse (the last one, cut off by a kill) is skipped,
/// never fatal. Every line ends in a field whose cut-off form does not
/// parse: a time loses digits and falls before 2001, an id loses its UUID
/// shape, an accuracy loses the one decimal the writer always gives it
/// ("30.0" cut to "3" is no accuracy).
enum RunLog {
    private static let minTime: Int64 = 1_000_000_000_000
    // The widest offsets in use are -12:00 and +14:00; allow 18 h like java.time.
    private static let maxOffset = 18 * 3600

    static func line(_ event: RunEvent) -> String {
        switch event {
        case let .start(time, id, offset):
            guard let id, let offset else { return "S,\(time)" }
            return "S2,\(time),\(offset),\(id)"
        case let .pause(time): return "P,\(time)"
        case let .resume(time): return "R,\(time)"
        case let .stop(time): return "E,\(time)"
        case let .fix(fix):
            let altitude = fix.altitude.map { String(format: "%.1f", $0) } ?? ""
            return String(format: "F,%lld,%.7f,%.7f,", fix.time, fix.lat, fix.lon) + altitude + String(format: ",%.1f", fix.accuracy)
        }
    }

    static func parse(_ text: String) -> [RunEvent] {
        text.split(separator: "\n", omittingEmptySubsequences: false).compactMap { parseLine(String($0)) }
    }

    static func parseLine(_ line: String) -> RunEvent? {
        let parts = line.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        // A torn line can still parse ("S,17"): a time before 2001 is one.
        guard parts.count >= 2, isInteger(parts[1]), let time = Int64(parts[1]), time >= minTime else { return nil }
        switch parts[0] {
        case "S": return parts.count == 2 ? .start(time: time, recordingId: nil, utcOffsetSeconds: nil) : nil
        case "S2": return start(time, parts)
        case "P": return parts.count == 2 ? .pause(time: time) : nil
        case "R": return parts.count == 2 ? .resume(time: time) : nil
        case "E": return parts.count == 2 ? .stop(time: time) : nil
        case "F": return fix(time, parts)
        default: return nil
        }
    }

    /// A lowercase UUID, any version: the shape `UUID().uuidString.lowercased()` gives.
    static func isRecordingId(_ text: String) -> Bool {
        let groups = text.split(separator: "-", omittingEmptySubsequences: false)
        guard groups.map(\.count) == [8, 4, 4, 4, 12] else { return false }
        return groups.allSatisfy { $0.unicodeScalars.allSatisfy { ("0" ... "9").contains($0) || ("a" ... "f").contains($0) } }
    }

    // MARK: Private

    private static func start(_ time: Int64, _ parts: [String]) -> RunEvent? {
        guard parts.count == 4,
              isInteger(parts[2]), let offset = Int(parts[2]), (-maxOffset ... maxOffset).contains(offset),
              isRecordingId(parts[3])
        else { return nil }
        return .start(time: time, recordingId: parts[3], utcOffsetSeconds: offset)
    }

    private static func fix(_ time: Int64, _ parts: [String]) -> RunEvent? {
        guard parts.count == 6,
              let lat = decimal(parts[2]), (-90.0 ... 90.0).contains(lat),
              let lon = decimal(parts[3]), (-180.0 ... 180.0).contains(lon),
              hasOneDecimal(parts[5]), let accuracy = Double(parts[5])
        else { return nil }
        var altitude: Double?
        if !parts[4].isEmpty {
            guard let value = decimal(parts[4]) else { return nil }
            altitude = value
        }
        return .fix(RunFix(time: time, lat: lat, lon: lon, altitude: altitude, accuracy: accuracy))
    }

    // "-12", "1730000000000": digits with an optional minus, nothing else.
    private static func isInteger(_ text: String) -> Bool {
        let digits = text.hasPrefix("-") ? text.dropFirst() : Substring(text)
        return !digits.isEmpty && digits.unicodeScalars.allSatisfy { ("0" ... "9").contains($0) }
    }

    // A plain decimal ("-5.7945123", "12"), finite: no exponent, nan or inf.
    private static func decimal(_ text: String) -> Double? {
        let body = text.hasPrefix("-") ? text.dropFirst() : Substring(text)
        let pieces = body.split(separator: ".", omittingEmptySubsequences: false)
        guard (1 ... 2).contains(pieces.count),
              pieces.allSatisfy({ !$0.isEmpty && $0.unicodeScalars.allSatisfy { ("0" ... "9").contains($0) } })
        else { return nil }
        return Double(text).flatMap { $0.isFinite ? $0 : nil }
    }

    // "30.0", "4.5": digits, a point, exactly one digit, as the writer gives it.
    private static func hasOneDecimal(_ text: String) -> Bool {
        let pieces = text.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count == 2, !pieces[0].isEmpty, pieces[1].count == 1 else { return false }
        return pieces.allSatisfy { $0.unicodeScalars.allSatisfy { ("0" ... "9").contains($0) } }
    }
}
