import Foundation

/// The runs list's "Export CSV" link (/activities/export, in any locale, with
/// whatever filters it carries in its query) and the file it answers with.
/// Left to Hotwire, the link would become a visit that gets a CSV instead of
/// a page and shows an error, so `CsvExportRouteDecisionHandler` fetches it
/// and hands it to the share sheet. The Android app's rules (CsvExport.kt).
///
/// The same plain prefix match on the root URL plus a path pattern as
/// `SharePages`, no URL parser: anything unusual (another host, port or
/// scheme, an encoded character, a doubled slash, a path under the export)
/// fails closed, which here means it is left to in-app navigation.
/// "/activities/export.csv" is the same Rails action and is taken too;
/// "/activities/export.html" or any other format is not a CSV and is not.
enum CsvExport {
    static let fallbackFilename = "calcpace_activities.csv"

    /// Bigger than any athlete's history; anything past it is refused, not truncated.
    static let maxBytes = 8 * 1024 * 1024

    private static let exportPath = regex("^(?:/(?:\(SharePages.locales)))?/activities/export(?:\\.csv)?/?$")

    // Same rule as a share card's name (SharePayload): no path, nothing
    // hidden, and nothing a receiving app could read as anything but a name.
    private static let plainName = regex("^[A-Za-z0-9_-][A-Za-z0-9._-]{0,75}\\.csv$")
    private static let quoted = regex("(?i)(?:^|;)\\s*filename\\s*=\\s*\"([^\"]*)\"")
    private static let token = regex("(?i)(?:^|;)\\s*filename\\s*=\\s*([^\";\\s]+)")
    private static let extended = regex("(?i)(?:^|;)\\s*filename\\*\\s*=\\s*[A-Za-z0-9_-]*'[^']*'([^;\\s]+)")

    static func isExport(_ location: URL, rootURL: URL) -> Bool {
        let base = rootURL.absoluteString.hasSuffix("/") ? String(rootURL.absoluteString.dropLast()) : rootURL.absoluteString
        let location = location.absoluteString
        guard location.hasPrefix(base) else { return false }

        var path = Substring(location.dropFirst(base.count))
        if let end = path.firstIndex(where: { $0 == "#" || $0 == "?" }) { path = path[..<end] }
        return matches(exportPath, String(path))
    }

    /// The name the server gave the file in `contentDisposition`, e.g.
    /// `attachment; filename="calcpace_activities_2026-10-18.csv"; filename*=UTF-8''calcpace_activities_2026-10-18.csv`
    /// as Rails' send_data writes it, or `fallbackFilename` when there is
    /// none or it isn't a plain .csv name. The extended form is only taken
    /// when it needs no decoding: an escaped character would fail the name
    /// rule anyway.
    static func filename(_ contentDisposition: String?) -> String {
        guard let contentDisposition else { return fallbackFilename }

        for rule in [extended, quoted, token] {
            if let name = firstGroup(rule, contentDisposition), matches(plainName, name) { return name }
        }
        return fallbackFilename
    }

    /// "text/csv", with or without parameters. An HTML page (the sign-in page, an error) is not.
    static func isCSV(_ contentType: String?) -> Bool {
        guard let type = contentType?.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first else { return false }
        return type.trimmingCharacters(in: .whitespaces).lowercased() == "text/csv"
    }

    /// Whether a WebView cookie set for `domain` ("calcpace.app" or
    /// ".calcpace.app") goes with a request to `host`: the same host or one
    /// under it, never a host that only ends in the same letters.
    static func cookie(for domain: String, isSentTo host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        let domain = (domain.hasPrefix(".") ? String(domain.dropFirst()) : domain).lowercased()
        guard !domain.isEmpty else { return false }
        return host == domain || host.hasSuffix("." + domain)
    }

    // MARK: Private

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
