import Foundation

/// The finished run as GPX 1.1, the format the site already imports: one
/// track, one segment per stretch between pauses, every fix the `Track` kept
/// with its time and, when the GPS gave one, its height above sea level
/// (CLLocation.altitude). The Android app's Gpx.kt, with its creator.
///
/// A pause is the gap between two segments, which the site leaves out of the
/// run's time and distance.
///
/// The metadata carries the run's recording id and the phone's offset from
/// UTC at Start, in Calcpace's own extension, so the file says which run it
/// is wherever it ends up (shared by hand when the upload was refused).
enum Gpx {
    static let namespace = "https://calcpace.app/xmlns/recorder/1"

    static func write(_ track: Track, name: String) -> String {
        var out = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        out += "<gpx version=\"1.1\" creator=\"Calcpace iOS\" xmlns=\"http://www.topografix.com/GPX/1/1\" xmlns:calcpace=\"\(namespace)\">\n"
        if let start = track.startedAt {
            out += "  <metadata><time>\(time(start))</time>"
            if let id = track.recordingId, let offset = track.utcOffsetSeconds {
                out += "<extensions><calcpace:recording id=\"\(escape(id))\" utc_offset=\"\(offset)\"/></extensions>"
            }
            out += "</metadata>\n"
        }
        out += "  <trk>\n"
        out += "    <name>\(escape(name))</name>\n"
        out += "    <type>running</type>\n"
        for segment in track.segments {
            out += "    <trkseg>\n"
            for fix in segment {
                out += String(format: "      <trkpt lat=\"%.7f\" lon=\"%.7f\">", fix.lat, fix.lon)
                if let altitude = fix.altitude { out += String(format: "<ele>%.1f</ele>", altitude) }
                out += "<time>\(time(fix.time))</time></trkpt>\n"
            }
            out += "    </trkseg>\n"
        }
        out += "  </trk>\n"
        out += "</gpx>\n"
        return out
    }

    /// The runner's local time, which is how they remember the run; to the
    /// second, so two runs started in the same minute keep both files.
    static func filename(_ startedAt: Int64, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return "calcpace-" + formatter.string(from: date(startedAt)) + ".gpx"
    }

    static func date(_ epochMillis: Int64) -> Date {
        Date(timeIntervalSince1970: Double(epochMillis) / 1000)
    }

    // MARK: Private

    private static let utc: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        return formatter
    }()

    private static func time(_ epochMillis: Int64) -> String {
        utc.string(from: date(epochMillis))
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
