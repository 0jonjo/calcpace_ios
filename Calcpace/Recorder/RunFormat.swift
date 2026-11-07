import Foundation

/// The numbers on the recording screen as a runner reads them: the distance
/// in the unit the run counts in, with the decimal mark of the screen's
/// language ("5,21 km" in Portuguese). The Android app's RunFormat.kt.
enum RunFormat {
    static let metersPerMile = 1609.344

    enum Unit: String, CaseIterable {
        case km = "KM"
        case mi = "MI"

        var meters: Double { self == .km ? 1000 : RunFormat.metersPerMile }
        var label: String { self == .km ? "km" : "mi" }

        /// Miles where runners count in them: the US, Liberia, Myanmar.
        static func defaultFor(region: String?) -> Unit {
            ["US", "LR", "MM"].contains(region ?? "") ? .mi : .km
        }

        /// The site's language first: every one but English is read in
        /// kilometres, so a Portuguese screen on a phone set to US English
        /// starts in km. English leaves it to the phone's country.
        static func defaultFor(siteLocale: String?, region: String?) -> Unit {
            if let siteLocale, siteLocale != "en" { return .km }
            return defaultFor(region: region)
        }

        /// The site's own spelling (`/record?unit=km`).
        static func site(_ value: String?) -> Unit? {
            switch value {
            case "km": return .km
            case "mi": return .mi
            default: return nil
            }
        }
    }

    /// "0:42", "12:05", "1:02:09".
    static func clock(_ millis: Int64) -> String {
        let total = max(millis / 1000, 0)
        let hours = total / 3600
        let minutes = total % 3600 / 60
        let seconds = total % 60
        return hours > 0
            ? String(format: "%lld:%02lld:%02lld", hours, minutes, seconds)
            : String(format: "%lld:%02lld", minutes, seconds)
    }

    /// "3.42 km", "3,42 km", "2.13 mi": two decimals, rounded half up as the
    /// site rounds them, so the run reads the same once it is there.
    static func distance(_ meters: Double, unit: Unit = .km, locale: Locale = Locale(identifier: "en_US_POSIX")) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        formatter.usesGroupingSeparator = false
        // Rounded as written (2.905 is 2.91), not as the double holds it
        // (2.90499…): the shortest decimal that reads back as the double.
        var value = Decimal(string: "\(max(meters, 0) / unit.meters)", locale: Locale(identifier: "en_US_POSIX")) ?? 0
        var rounded = Decimal()
        NSDecimalRound(&rounded, &value, 2, .plain)
        let number = formatter.string(from: NSDecimalNumber(decimal: rounded)) ?? "0.00"
        return "\(number) \(unit.label)"
    }

    /// "5:07 /km", or "–:– /km" before there is a pace to show.
    /// `secondsPerKm` is always per kilometre; `unit` says what to show it per.
    static func pace(_ secondsPerKm: Double?, unit: Unit = .km) -> String {
        guard let perUnit = secondsPerKm.map({ $0 * unit.meters / 1000 }), perUnit.isFinite, perUnit < 3600 else {
            return "–:– /\(unit.label)"
        }
        let rounded = Int(perUnit.rounded())
        return String(format: "%d:%02d", rounded / 60, rounded % 60) + " /" + unit.label
    }
}
