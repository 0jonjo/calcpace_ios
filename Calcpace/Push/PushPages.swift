import Foundation

/// Where the "push" bridge component may be driven from: the site's home
/// page, where its card lives, in any locale, and nowhere else. The WebView's
/// JavaScript bridge is reachable from any frame on any page, so a message
/// from elsewhere is ignored rather than allowed to raise the system prompt
/// or collect the device token. The Android app's PushPages, and the same
/// plain prefix match as HealthPages: anything unusual fails closed.
enum PushPages {
    private static let home = try! NSRegularExpression(pattern: "^(?:/(?:\(SharePages.locales)))?/?$")

    static func isHome(_ location: URL?, rootURL: URL) -> Bool {
        let base = rootURL.absoluteString.hasSuffix("/") ? String(rootURL.absoluteString.dropLast()) : rootURL.absoluteString
        guard let location = location?.absoluteString, location.hasPrefix(base) else { return false }

        var path = Substring(location.dropFirst(base.count))
        if let end = path.firstIndex(where: { $0 == "#" || $0 == "?" }) { path = path[..<end] }
        let candidate = String(path)
        let range = NSRange(candidate.startIndex ..< candidate.endIndex, in: candidate)
        return home.firstMatch(in: candidate, range: range) != nil
    }
}
