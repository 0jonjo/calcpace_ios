import Foundation

/// Reads a "your run is in" notification the server sends through APNs:
///
///     {"aps": {"alert": {"title": "…", "body": "…"}, "sound": "default"},
///      "path": "/pt-BR/activities/123"}
///
/// iOS draws the notification itself; the app only needs the page a tap
/// opens: the site's root URL plus `path`. The Android app's PushPayload, and
/// the same rules, since a tap opens that URL in the app with the athlete's
/// session: a plain path on the site, never one with a scheme or a host of
/// its own. The cheap string guards run before any URL parser sees it, since
/// the WebView reads "\" as "/" whatever Foundation thinks, and the URL that
/// comes out must still be on the site's host.
///
/// Anything off, a missing title or body included (that is not what the
/// server sends), and the tap just brings the app to the front.
enum PushPayload {
    static let maxPath = 2048

    struct Notice: Equatable {
        let title: String
        let body: String
        let url: URL
    }

    static func parse(_ userInfo: [AnyHashable: Any], rootURL: URL) -> Notice? {
        guard let aps = userInfo["aps"] as? [String: Any],
              let alert = aps["alert"] as? [String: Any],
              let title = (alert["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty,
              let body = (alert["body"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !body.isEmpty,
              let path = userInfo["path"] as? String,
              isPlainPath(path)
        else { return nil }

        let base = rootURL.absoluteString.hasSuffix("/") ? String(rootURL.absoluteString.dropLast()) : rootURL.absoluteString
        guard let url = URL(string: base + path),
              url.scheme == rootURL.scheme,
              url.host == rootURL.host,
              url.port == rootURL.port,
              url.user == nil,
              url.password == nil
        else { return nil }

        return Notice(title: title, body: body, url: url)
    }

    // "/x", never "//host", "/\host", or anything the WebView would silently
    // drop or rewrite (whitespace, control characters). The length counts
    // UTF-16 units, as the Android app's does.
    static func isPlainPath(_ path: String) -> Bool {
        path.utf16.count <= maxPath &&
            path.hasPrefix("/") &&
            !path.hasPrefix("//") &&
            !path.unicodeScalars.contains { $0 == "\\" || $0.value <= 0x20 || $0.value == 0x7F }
    }
}
