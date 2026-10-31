import Foundation

/// Signing in with Google or Strava from inside the app.
///
/// Google refuses OAuth inside a WebView, and the sign-in browser keeps its
/// own cookies, so the sign-in runs in an ASWebAuthenticationSession and is
/// handed back:
///
/// 1. The site's in-app button links to /app_auth/google (or /strava);
///    `AppAuthRouteDecisionHandler` catches it and calls `begin(provider:)`.
/// 2. `begin` keeps a fresh verifier and gives the session
///    /app_auth/start?provider=…&challenge=…&platform=ios to open.
/// 3. After the provider, the site sends the session to
///    app.calcpace.ios://app_auth/callback?ticket=…, which the session hands
///    to the app that started it, and to no other
///    (`ticket(fromCallback:)`).
/// 4. `redeemLocation(ticket:)` points the WebView at /app_auth/redeem with
///    the ticket and the verifier, which signs the WebView in.
///
/// The ticket is bound to the challenge; only this app ever held the
/// verifier. A callback does not spend the verifier, as in the Android app
/// (AppAuth.kt), where any app can send one; the site burns every ticket on
/// first use, right or wrong. The verifier goes once a redeem lands somewhere
/// other than the sign-in page (`visitCompleted`), or when it expires.
///
/// Main thread only: the router and the session's completion call in on it.
final class AppAuth {
    static let shared = AppAuth(rootURL: AppDelegate.rootURL)

    static let providers: Set<String> = ["google", "strava"]

    /// The scheme the site sends an iPhone's sign-in back on. Not registered
    /// in Info.plist: the web authentication session catches it itself, and
    /// no other app, nor a link anywhere, can open the app with it.
    static let callbackScheme = "app.calcpace.ios"

    // As long as the site keeps the challenge bound to the provider's state
    // (AppAuthHandoff::BOUND_TTL: a Strava sign-up can sit on the finish
    // screen for a while).
    static let ttl: TimeInterval = 30 * 60

    // The site's AppAuthTicket::TOKEN_FORMAT: 32 random bytes, base64url.
    private static let ticketFormat = try! NSRegularExpression(pattern: "^[A-Za-z0-9_-]{43}\\z")

    private static let verifierKey = "appAuth.verifier"
    private static let startedAtKey = "appAuth.startedAt"

    private let rootURL: URL
    private let defaults: UserDefaults
    private let now: () -> Date

    // The one redeem URL the WebView may load, set just before routing to it.
    // A redeem link arriving any other way is refused by the route handler.
    private var expectedRedeem: URL?

    // A redeem was sent and its outcome is not known yet.
    private var redeemInFlight = false

    init(rootURL: URL, defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.rootURL = rootURL
        self.defaults = defaults
        self.now = now
    }

    /// The page that starts `provider`'s sign-in, for the web authentication
    /// session to open, with a fresh verifier kept for it. Nil for anything
    /// but Google and Strava.
    func begin(provider: String) -> URL? {
        guard Self.providers.contains(provider), let verifier = Pkce.newVerifier() else { return nil }

        var components = URLComponents(url: rootURL, resolvingAgainstBaseURL: false)
        components?.path = "/app_auth/start"
        components?.query = nil
        components?.fragment = nil
        components?.queryItems = [
            URLQueryItem(name: "provider", value: provider),
            URLQueryItem(name: "challenge", value: Pkce.challenge(for: verifier)),
            URLQueryItem(name: "platform", value: "ios")
        ]
        guard let start = components?.url else { return nil }

        // A new sign-in: whatever an earlier one left half done is over.
        expectedRedeem = nil
        redeemInFlight = false
        // In UserDefaults only because it is the simplest store: the
        // session, and with it the callback, lives in this process
        // (AppAuthBrowser), so a relaunched app never gets to use it. The
        // TTL, a good redeem or the next sign-in clears it.
        defaults.set(verifier, forKey: Self.verifierKey)
        defaults.set(now().timeIntervalSince1970, forKey: Self.startedAtKey)
        return start
    }

    /// The ticket in the site's callback, or nil for anything that isn't
    /// exactly app.calcpace.ios://app_auth/callback?ticket=<ticket>.
    static func ticket(fromCallback url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == callbackScheme,
              components.host?.lowercased() == "app_auth",
              components.percentEncodedPath == "/callback",
              components.user == nil, components.password == nil, components.port == nil,
              let tickets = components.queryItems?.filter({ $0.name == "ticket" }),
              tickets.count == 1,
              let ticket = tickets[0].value,
              isTicket(ticket)
        else { return nil }
        return ticket
    }

    static func isTicket(_ ticket: String) -> Bool {
        ticketFormat.firstMatch(in: ticket, range: NSRange(ticket.startIndex ..< ticket.endIndex, in: ticket)) != nil
    }

    /// The WebView location that completes the sign-in, or nil when no
    /// sign-in of ours is waiting (none started, or it expired). It is the
    /// one redeem the route handler lets through (`takeExpectedRedeem`).
    func redeemLocation(ticket: String) -> URL? {
        guard Self.isTicket(ticket), let verifier = freshVerifier() else { return nil }

        var components = URLComponents(url: rootURL, resolvingAgainstBaseURL: false)
        components?.path = "/app_auth/redeem"
        components?.query = nil
        components?.fragment = nil
        components?.queryItems = [
            URLQueryItem(name: "ticket", value: ticket),
            URLQueryItem(name: "verifier", value: verifier)
        ]
        guard let redeem = components?.url else { return nil }

        expectedRedeem = redeem
        redeemInFlight = true
        return redeem
    }

    /// True once for the URL `redeemLocation` just built.
    func takeExpectedRedeem(_ location: URL) -> Bool {
        guard let expected = expectedRedeem, expected.absoluteString == location.absoluteString else { return false }
        expectedRedeem = nil
        return true
    }

    /// Every finished visit passes here. The first one after a redeem that
    /// is no longer under app_auth tells how it went: the site sends a failed
    /// redeem to the sign-in page and a good one anywhere else. Only a good
    /// one spends the verifier.
    ///
    func visitCompleted(_ location: URL) {
        guard redeemInFlight, let succeeded = AppAuthPaths.redeemSucceeded(location.absoluteString) else { return }

        redeemInFlight = false
        if succeeded { clear() }
    }

    /// A visit that failed (SceneDelegate's visitableDidFailRequest): a
    /// redeem that never got an answer keeps the verifier, and the next
    /// visit is not taken for its outcome.
    func visitFailed() {
        redeemInFlight = false
    }

    // MARK: Private

    private func freshVerifier() -> String? {
        let startedAt = defaults.double(forKey: Self.startedAtKey)
        let age = now().timeIntervalSince1970 - startedAt
        guard startedAt > 0, age >= 0, age <= Self.ttl else {
            clear()
            return nil
        }
        return defaults.string(forKey: Self.verifierKey)
    }

    private func clear() {
        defaults.removeObject(forKey: Self.verifierKey)
        defaults.removeObject(forKey: Self.startedAtKey)
    }
}
