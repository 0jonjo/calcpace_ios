import Foundation

/// Where the "apple-health" bridge component may be driven from: the site's
/// home page (the Apple Health card) and Settings › Apple Health, in any
/// locale, and nowhere else. The WebView's JavaScript bridge is reachable
/// from any frame on any page, so a message from elsewhere is ignored rather
/// than allowed to open the HealthKit sheet or hand the app a link token.
/// The Android app's HcPages, and the same plain prefix match as SharePages:
/// anything unusual fails closed.
enum HealthPages {
    private static let allowed = try! NSRegularExpression(pattern: "^(?:/(?:\(SharePages.locales)))?(?:/settings/apple-health)?/?$")

    static func isAllowed(_ location: URL?, rootURL: URL) -> Bool {
        let base = rootURL.absoluteString.hasSuffix("/") ? String(rootURL.absoluteString.dropLast()) : rootURL.absoluteString
        guard let location = location?.absoluteString, location.hasPrefix(base) else { return false }

        var path = Substring(location.dropFirst(base.count))
        if let end = path.firstIndex(where: { $0 == "#" || $0 == "?" }) { path = path[..<end] }
        let candidate = String(path)
        let range = NSRange(candidate.startIndex ..< candidate.endIndex, in: candidate)
        return allowed.firstMatch(in: candidate, range: range) != nil
    }
}
