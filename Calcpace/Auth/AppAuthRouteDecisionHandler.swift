import AuthenticationServices
import HotwireNative
import UIKit

/// Guards every in-app navigation that touches app_auth, however the path is
/// spelled (see `AppAuthPaths`). As in the Android app
/// (AppAuthRouteDecisionHandler.kt):
///
/// - /app_auth/google and /app_auth/strava, the site's in-app sign-in
///   buttons, run the sign-in in a web authentication session instead
///   (`AppAuthBrowser`). See `AppAuth`.
/// - /app_auth/redeem loads only when `AppAuth` built that exact URL. A
///   redeem link anywhere else (a bio, a run name, a page the athlete was
///   sent to) would sign the WebView into someone else's account.
/// - Everything else there is refused.
///
/// It matches on the host alone, as broadly as the in-app navigation handler
/// after it, so nothing it refuses can slip through on another scheme or
/// port. Registered first, before the CSV export and in-app navigation.
final class AppAuthRouteDecisionHandler: RouteDecisionHandler {
    let name = "app-auth"

    private let auth: AppAuth
    private let signIn: (String, Navigating) -> Void

    /// `signIn` opens the provider's sign-in; the tests stand in for the browser.
    init(auth: AppAuth = .shared, signIn: @escaping (String, Navigating) -> Void = AppAuthRouteDecisionHandler.openBrowser) {
        self.auth = auth
        self.signIn = signIn
    }

    func matches(proposal: VisitProposal, configuration: Navigator.Configuration) -> Bool {
        AppAuthPaths.isGuarded(proposal.url.absoluteString, host: configuration.startLocation.host)
    }

    func handle(proposal: VisitProposal, configuration: Navigator.Configuration, navigator: Navigating) -> Router.Decision {
        let location = proposal.url
        guard IncomingLink.isSite(location, rootURL: configuration.startLocation) else { return .cancel }

        if let provider = AppAuthPaths.provider(of: location.absoluteString) {
            signIn(provider, navigator)
            return .cancel
        }

        if AppAuthPaths.isRedeem(location.absoluteString) && auth.takeExpectedRedeem(location) {
            return .navigate
        }

        return .cancel
    }

    static func openBrowser(_ provider: String, _ navigator: Navigating) {
        Task { @MainActor in AppAuthBrowser.shared.signIn(with: provider, navigator: navigator) }
    }
}

/// The web authentication session a sign-in runs in, one at a time: a tap
/// while one is open is ignored. The session is held until it finishes (iOS
/// tears it down if it is let go), and shares Safari's cookies
/// (prefersEphemeralWebBrowserSession off) so a password manager or a
/// provider already signed in there helps; the site never hands over a
/// session it finds there, and always shows the provider's account choice.
///
/// A good callback routes the WebView to the redeem; anything else (the
/// athlete closing the sheet, a callback that isn't the site's, a sign-in
/// that expired) leaves the app where it was, with nothing to show.
@MainActor
final class AppAuthBrowser: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = AppAuthBrowser()

    private var session: ASWebAuthenticationSession?
    // Which session a callback belongs to: one that couldn't start may still
    // call back with its error, after the next has begun.
    private var attempt = 0
    private var anchor: UIWindow?
    private weak var navigator: Navigating?

    func signIn(with provider: String, navigator: Navigating) {
        // The sheet needs a window on screen to come up from.
        guard session == nil,
              let window = navigator.rootViewController.viewIfLoaded?.window,
              let start = AppAuth.shared.begin(provider: provider)
        else { return }

        attempt += 1
        let current = attempt
        let session = ASWebAuthenticationSession(url: start, callbackURLScheme: AppAuth.callbackScheme) { [weak self] callbackURL, _ in
            let ticket = callbackURL.flatMap { AppAuth.ticket(fromCallback: $0) }
            Task { @MainActor [weak self] in self?.finish(current, ticket: ticket) }
        }
        session.presentationContextProvider = self
        session.prefersEphemeralWebBrowserSession = false

        self.session = session
        self.anchor = window
        self.navigator = navigator
        if !session.start() { finish(current, ticket: nil) }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        anchor ?? ASPresentationAnchor()
    }

    private func finish(_ attempt: Int, ticket: String?) {
        guard attempt == self.attempt, session != nil else { return }

        let navigator = navigator
        session = nil
        anchor = nil
        self.navigator = nil

        guard let ticket, let navigator, let redeem = AppAuth.shared.redeemLocation(ticket: ticket) else { return }
        navigator.route(redeem)
    }
}
