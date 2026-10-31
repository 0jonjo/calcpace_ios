import Foundation

/// What a link handed to the app from outside is allowed to do. The Android
/// app's IncomingLink.kt, on the same rules (IncomingLinkTests).
///
/// Not every calcpace.app path may be loaded into the WebView from outside:
/// /app_auth/redeem signs the WebView in, so a redeem link mailed by an
/// attacker would sign the victim into the attacker's account. Only `AppAuth`
/// builds redeem URLs.
///
/// On iPhone, only `.web` is ever acted on (`location(forOutsideLink:)`):
///
/// - A sign-in comes back only through the web authentication session that
///   started it (`AppAuthBrowser`), on the app.calcpace.ios scheme, never as
///   a link from outside. So `.signIn`, the Android app's App Link callback,
///   is ignored here.
/// - `.browserTab`, a provider step whose OAuth state lives in the sign-in
///   browser's cookies, has no tab to go back to: the session is the only
///   browser holding that state, and it keeps the step to itself. In the
///   WebView the step would fail the state check.
///
/// Universal links aren't set up yet (no Team ID for the site's
/// apple-app-site-association), so for now nothing reaches this but what
/// iOS may hand over on its own; the rules are ready for when they are.
enum IncomingLink: Equatable {
    /// The site finished a sign-in started by this app.
    case signIn(ticket: String)

    /// A provider step whose OAuth state lives in the sign-in browser.
    case browserTab(URL)

    /// An ordinary page.
    case web(URL)

    case ignore

    static func classify(_ url: URL, rootURL: URL) -> IncomingLink {
        guard isSite(url, rootURL: rootURL) else { return .ignore }

        let location = url.absoluteString
        if AppAuthPaths.isGuarded(location, host: rootURL.host) {
            guard AppAuthPaths.isCallback(location), let ticket = ticket(in: url) else { return .ignore }
            return .signIn(ticket: ticket)
        }
        if AppAuthPaths.isProviderStep(location) { return .browserTab(url) }
        return .web(url)
    }

    /// Where a link from outside (a universal link, a web page handed over)
    /// takes the WebView, or nil to stay put. Ordinary pages only.
    static func location(forOutsideLink url: URL, rootURL: URL) -> URL? {
        guard case .web(let location) = classify(url, rootURL: rootURL) else { return nil }
        return location
    }

    /// Same scheme, host and port as the site.
    static func isSite(_ url: URL, rootURL: URL) -> Bool {
        guard let scheme = url.scheme, let host = url.host,
              let rootScheme = rootURL.scheme, let rootHost = rootURL.host
        else { return false }
        return scheme.lowercased() == rootScheme.lowercased() &&
            host.lowercased() == rootHost.lowercased() &&
            url.port == rootURL.port
    }

    private static func ticket(in url: URL) -> String? {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard let ticket = items.first(where: { $0.name == "ticket" })?.value, AppAuth.isTicket(ticket) else { return nil }
        return ticket
    }
}
