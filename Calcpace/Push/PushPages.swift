import Foundation

/// Where the "push" bridge component may be driven from, in any locale: the
/// site's home page, where its card lives, and Settings' list and
/// notifications page, where the "Notifications" row and its page are
/// (settings/_notifications_row, settings/notifications/show). Nowhere else.
/// The WebView's JavaScript bridge is reachable from any frame on any page,
/// so a message from elsewhere is ignored rather than allowed to raise the
/// system prompt or collect the device token. The Android app's PushPages
/// (home only until its next build), and the same plain prefix match as
/// HealthPages: anything unusual fails closed.
enum PushPages {
    private static let allowed = try! NSRegularExpression(
        pattern: "^(?:/(?:\(SharePages.locales)))?(?:/settings(?:/notifications)?)?/?$"
    )

    static func allows(_ location: URL?, rootURL: URL) -> Bool {
        let base = rootURL.absoluteString.hasSuffix("/") ? String(rootURL.absoluteString.dropLast()) : rootURL.absoluteString
        guard let location = location?.absoluteString, location.hasPrefix(base) else { return false }

        var path = Substring(location.dropFirst(base.count))
        if let end = path.firstIndex(where: { $0 == "#" || $0 == "?" }) { path = path[..<end] }
        let candidate = String(path)
        let range = NSRange(candidate.startIndex ..< candidate.endIndex, in: candidate)
        return allowed.firstMatch(in: candidate, range: range) != nil
    }
}
