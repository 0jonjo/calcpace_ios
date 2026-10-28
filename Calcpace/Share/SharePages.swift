import Foundation

/// Where the "share-image" bridge component may be driven from: a run's page
/// (/activities/<id>, in any locale), where the share dialog lives. A message
/// sent while the WebView shows any other page is ignored rather than allowed
/// to write files and open the share sheet. The Android app's rule
/// (SharePages.kt), and the same caveat: only the main frame's URL is checked,
/// which holds because a run page is shown to its owner alone and embeds no
/// third-party frames.
///
/// A plain prefix match on the root URL plus a path pattern, no URL parser:
/// anything unusual (an encoded character, a doubled slash, another route
/// under the run) fails closed.
enum SharePages {
    static let locales = "en|pt-BR|es|de|fr|ja|it|nl|ko|sv|pl|no|zh-TW|hu|cs|ru"

    private static let runPath = try! NSRegularExpression(pattern: "^(?:/(?:\(locales)))?/activities/[0-9]+/?$")

    static func isRunPage(_ location: URL?, rootURL: URL) -> Bool {
        let base = rootURL.absoluteString.hasSuffix("/") ? String(rootURL.absoluteString.dropLast()) : rootURL.absoluteString
        guard let location = location?.absoluteString, location.hasPrefix(base) else { return false }

        var path = Substring(location.dropFirst(base.count))
        if let end = path.firstIndex(where: { $0 == "#" || $0 == "?" }) { path = path[..<end] }
        let candidate = String(path)
        let range = NSRange(candidate.startIndex ..< candidate.endIndex, in: candidate)
        return runPath.firstMatch(in: candidate, range: range) != nil
    }
}
