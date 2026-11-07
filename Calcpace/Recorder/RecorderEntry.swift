import Foundation

/// The site's way into the recorder: the round Record button in the middle of
/// its tab bar links to /record (shared/_bottom_nav_record on the site), in
/// any of its languages and with the athlete's unit (`?unit=km`). The site
/// draws that button only for a build whose user agent lists the "recorder"
/// bridge component (`RecorderComponent`), and `RecordRouteDecisionHandler`
/// opens the recording screen instead of the page. The Android app's
/// RecorderEntry.kt.
///
/// A plain prefix match on the root URL plus a path pattern, as `SharePages`:
/// anything unusual fails closed and loads as a page.
enum RecorderEntry {
    struct Visit: Equatable {
        /// The site's language from the path ("pt-BR"), nil for a bare /record.
        let locale: String?
        /// The athlete's unit, when the link carries one.
        let unit: RunFormat.Unit?
    }

    private static let recordPath = try! NSRegularExpression(pattern: "^(?:/(\(SharePages.locales)))?/record/?$")

    static func visit(_ location: URL?, rootURL: URL) -> Visit? {
        let base = rootURL.absoluteString.hasSuffix("/") ? String(rootURL.absoluteString.dropLast()) : rootURL.absoluteString
        guard let location = location?.absoluteString, location.hasPrefix(base) else { return nil }

        var path = Substring(location.dropFirst(base.count))
        if let end = path.firstIndex(where: { $0 == "#" || $0 == "?" }) { path = path[..<end] }
        let candidate = String(path)
        let range = NSRange(candidate.startIndex ..< candidate.endIndex, in: candidate)
        guard let match = recordPath.firstMatch(in: candidate, range: range) else { return nil }

        let locale = Range(match.range(at: 1), in: candidate).map { String(candidate[$0]) }
        let unit = URLComponents(string: location)?.queryItems?.first { $0.name == "unit" }?.value
        return Visit(locale: locale, unit: RunFormat.Unit.site(unit))
    }
}
