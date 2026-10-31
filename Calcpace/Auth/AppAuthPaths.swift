import Foundation

/// Path rules for the sign-in hand-off, shared by everything that decides
/// what a calcpace.app URL may do. The Android app's AppAuthPaths.kt, on the
/// same cases (AppAuthPathsTests).
///
/// The site does not route on the raw path: Rails collapses "//" and the
/// WebView resolves "/./" and "%2e" before the request leaves. Matching only
/// the exact path would let "//app_auth/redeem" through to the redeem
/// action. So anything whose cleaned-up path so much as mentions app_auth
/// is guarded, and only the exact canonical paths are let through.
///
/// URLs are read with a deliberately lenient hand-written parser, never
/// URLComponents: a guard that gives up on what it can't parse lets exactly
/// that URL through to the next route handler. Whatever http(s) or
/// scheme-less URL this parser can't read is guarded too; other schemes
/// (mailto:, tel:) are not the site's and pass to the system.
///
/// Before parsing, a URL is normalised the way browsers do it (outer
/// whitespace and C0 trimmed, tab/CR/LF dropped, "\" read as "/"), so the
/// host and path seen here are the ones the WebView would request even if a
/// raw string ever reached the router.
enum AppAuthPaths {
    private static let prefix = "(?:/(?:\(SharePages.locales)))?"

    // \z, not $: the whole path, as Kotlin's matchEntire, with no room for a
    // trailing newline that "%0a" could decode into.
    private static let providerPath = regex("^\(prefix)/app_auth/(google|strava)\\z")
    private static let redeemPath = regex("^\(prefix)/app_auth/redeem\\z")
    private static let callbackPath = regex("^\(prefix)/app_auth/callback\\z")
    private static let providerStepPath = regex("^\(prefix)/auth(?:/.*)?\\z")
    private static let signInPath = regex("^\(prefix)/session(?:/new)?\\z")
    private static let absoluteURL = regex("^([A-Za-z][A-Za-z0-9+.-]*)://([^/?#]*)([^?#]*)")
    private static let schemePrefix = regex("^([A-Za-z][A-Za-z0-9+.-]*):")

    private struct Parts {
        let host: String
        let rawPath: String
        let cleanPath: String
    }

    /// True for any URL on `host` whose path, however spelled, touches app_auth, and for anything unreadable.
    static func isGuarded(_ url: String, host: String?) -> Bool {
        guard let parts = parse(url) else { return isWebOrUnknownScheme(url) }
        guard let host else { return false }
        return parts.host == host.lowercased() && parts.cleanPath.range(of: "app_auth", options: .caseInsensitive) != nil
    }

    /// "google" or "strava" for the site's in-app sign-in buttons, with or without a locale.
    static func provider(of url: String) -> String? {
        parse(url).flatMap { firstGroup(providerPath, $0.rawPath) }
    }

    static func isRedeem(_ url: String) -> Bool {
        parse(url).map { matches(redeemPath, $0.rawPath) } ?? false
    }

    static func isCallback(_ url: String) -> Bool {
        parse(url).map { matches(callbackPath, $0.rawPath) } ?? false
    }

    /// /auth/… with or without a locale, however spelled.
    static func isProviderStep(_ url: String) -> Bool {
        parse(url).map { matches(providerStepPath, $0.cleanPath) } ?? false
    }

    /// After a redeem, what the first finished visit says: nil while still
    /// under app_auth, false when the site sent it to the sign-in page (the
    /// redeem failed), true when it landed anywhere else (it worked).
    static func redeemSucceeded(_ location: String) -> Bool? {
        guard let path = parse(location)?.cleanPath else { return false }
        if path.range(of: "app_auth", options: .caseInsensitive) != nil { return nil }
        return !matches(signInPath, path)
    }

    // MARK: Private

    private static func isWebOrUnknownScheme(_ url: String) -> Bool {
        guard let scheme = firstGroup(schemePrefix, normalize(url))?.lowercased() else { return true }
        return scheme == "http" || scheme == "https"
    }

    private static func normalize(_ url: String) -> String {
        let scalars = Array(url.unicodeScalars)
        var start = 0
        var end = scalars.count
        while start < end, scalars[start].value <= 0x20 { start += 1 }
        while end > start, scalars[end - 1].value <= 0x20 { end -= 1 }
        var kept = String.UnicodeScalarView()
        for scalar in scalars[start ..< end] where scalar != "\t" && scalar != "\n" && scalar != "\r" {
            kept.append(scalar)
        }
        return String(kept).replacingOccurrences(of: "\\", with: "/")
    }

    private static func parse(_ url: String) -> Parts? {
        let text = normalize(url)
        guard let match = absoluteURL.firstMatch(in: text, range: NSRange(text.startIndex ..< text.endIndex, in: text)),
              let authorityRange = Range(match.range(at: 2), in: text),
              let pathRange = Range(match.range(at: 3), in: text)
        else { return nil }

        var authority = Substring(text[authorityRange])
        if let at = authority.lastIndex(of: "@") { authority = authority[authority.index(after: at)...] }
        var host: String
        if authority.hasPrefix("[") {
            host = String(authority.prefix { $0 != "]" }) + "]"
        } else {
            host = String(authority.prefix { $0 != ":" })
        }
        host = host.lowercased()
        while host.hasSuffix(".") { host.removeLast() }

        let rawPath = text[pathRange].isEmpty ? "/" : String(text[pathRange])
        return Parts(host: host, rawPath: rawPath, cleanPath: clean(rawPath))
    }

    // Decoded, repeated slashes collapsed, dot segments resolved: roughly
    // what the request will look like once it reaches Rails.
    private static func clean(_ rawPath: String) -> String {
        var segments: [String] = []
        for segment in decode(rawPath).components(separatedBy: "/") {
            switch segment {
            case "", ".": continue
            case "..": _ = segments.popLast()
            default: segments.append(segment)
            }
        }
        return "/" + segments.joined(separator: "/")
    }

    // Percent-decoding that never fails: a malformed escape stays as typed,
    // and bytes that aren't UTF-8 become U+FFFD.
    private static func decode(_ text: String) -> String {
        let bytes = Array(text.utf8)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var i = 0
        while i < bytes.count {
            if bytes[i] == UInt8(ascii: "%"), i + 2 < bytes.count,
               let high = hexValue(bytes[i + 1]), let low = hexValue(bytes[i + 2]) {
                out.append(high * 16 + low)
                i += 3
            } else {
                out.append(bytes[i])
                i += 1
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    // One hex digit exactly: "+1" or "-1" after a "%" is no escape.
    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0") ... UInt8(ascii: "9"): return byte - UInt8(ascii: "0")
        case UInt8(ascii: "a") ... UInt8(ascii: "f"): return byte - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A") ... UInt8(ascii: "F"): return byte - UInt8(ascii: "A") + 10
        default: return nil
        }
    }

    private static func regex(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern)
    }

    private static func matches(_ regex: NSRegularExpression, _ string: String) -> Bool {
        regex.firstMatch(in: string, range: NSRange(string.startIndex ..< string.endIndex, in: string)) != nil
    }

    private static func firstGroup(_ regex: NSRegularExpression, _ string: String) -> String? {
        guard let match = regex.firstMatch(in: string, range: NSRange(string.startIndex ..< string.endIndex, in: string)),
              let range = Range(match.range(at: 1), in: string)
        else { return nil }
        return String(string[range])
    }
}
