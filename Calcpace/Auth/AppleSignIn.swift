import AuthenticationServices
import HotwireNative
import UIKit

/// Sign in with Apple, natively: the site's "Sign in with Apple" button in
/// the iPhone app links to /app_auth/apple, which `AppAuthRouteDecisionHandler`
/// hands here instead of loading.
///
/// 1. `AppAuth.beginApple()` keeps a fresh verifier; its challenge is the
///    request's nonce. Only the email is asked for, no name.
/// 2. Apple's sheet gives an identity token (carrying the nonce) and an
///    authorization code, which go to the site with the challenge
///    (`AppleSignInExchange`).
/// 3. The site's ticket opens the same /app_auth/redeem as the other
///    sign-ins. No ticket, or an error from Apple, opens /app_auth/failed,
///    the sign-in page with the site's error. The athlete closing the sheet
///    leaves the app where it was.
///
/// One at a time, like `AppAuthBrowser`, and not while it has a session
/// open: a tap while either is under way is ignored. The controller is held
/// until the site has answered (iOS drops a sign-in whose controller is let
/// go), which also keeps a second tap out until then.
///
/// Needs the Sign in with Apple capability on the App ID (project.yml);
/// without it the sheet fails, and the WebView lands on /app_auth/failed.
@MainActor
final class AppleSignIn: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    static let shared = AppleSignIn()

    /// The button's path segment, /app_auth/apple (`AppAuthPaths.provider`).
    static let provider = "apple"

    private let auth: AppAuth
    private let rootURL: URL
    private let otherIsBusy: @MainActor () -> Bool
    private let perform: @MainActor (ASAuthorizationController) -> Void

    private var controller: ASAuthorizationController?
    private var challenge: String?
    private var anchor: UIWindow?
    private weak var navigator: Navigating?

    /// `otherIsBusy` is the web authentication session's; `perform` brings
    /// up Apple's sheet. The tests stand in for both.
    init(auth: AppAuth = .shared,
         rootURL: URL = AppDelegate.rootURL,
         otherIsBusy: @escaping @MainActor () -> Bool = { AppAuthBrowser.shared.isBusy },
         perform: @escaping @MainActor (ASAuthorizationController) -> Void = { $0.performRequests() }) {
        self.auth = auth
        self.rootURL = rootURL
        self.otherIsBusy = otherIsBusy
        self.perform = perform
        super.init()
    }

    var isBusy: Bool { controller != nil }

    func signIn(navigator: Navigating) {
        // The sheet needs a window on screen to come up from. Another
        // sign-in under way would have its verifier replaced by this one's.
        guard controller == nil, !otherIsBusy(),
              let window = navigator.rootViewController.viewIfLoaded?.window,
              let challenge = auth.beginApple()
        else { return }

        let controller = ASAuthorizationController(authorizationRequests: [Self.authorizationRequest(challenge: challenge)])
        controller.delegate = self
        controller.presentationContextProvider = self

        self.controller = controller
        self.challenge = challenge
        self.anchor = window
        self.navigator = navigator
        perform(controller)
    }

    /// Only the email, no name, with the challenge as the nonce.
    static func authorizationRequest(challenge: String) -> ASAuthorizationAppleIDRequest {
        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = [.email]
        // Raw on purpose: the site compares the token's nonce claim with the
        // challenge as sent. No SHA-256 here, unlike Firebase's guides, whose
        // server hashes the nonce it is given before comparing.
        request.nonce = challenge
        return request
    }

    /// Closing the sheet is no failure: nothing to show for it.
    nonisolated static func isCancel(_ error: Error) -> Bool {
        (error as? ASAuthorizationError)?.code == .canceled
    }

    // MARK: ASAuthorizationControllerPresentationContextProviding

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        anchor ?? ASPresentationAnchor()
    }

    // MARK: ASAuthorizationControllerDelegate

    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        guard controller === self.controller else { return }

        let credential = authorization.credential as? ASAuthorizationAppleIDCredential
        guard let challenge,
              let request = AppleSignInExchange.request(
                  identityToken: credential?.identityToken,
                  authorizationCode: credential?.authorizationCode,
                  challenge: challenge,
                  rootURL: rootURL,
                  userAgent: "\(AppUserAgent.prefix()) (Sign in with Apple)"
              )
        else { return finish(controller, ticket: nil) }

        Task { [weak self] in
            let ticket = await Self.sendKeepingAwake(request)
            self?.finish(controller, ticket: ticket)
        }
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        guard controller === self.controller else { return }

        if Self.isCancel(error) {
            end()
        } else {
            finish(controller, ticket: nil)
        }
    }

    // MARK: Private

    private func finish(_ controller: ASAuthorizationController, ticket: String?) {
        guard controller === self.controller else { return }

        let navigator = navigator
        end()
        let auth = auth
        navigator?.route(AppleSignInExchange.destination(ticket: ticket, rootURL: rootURL) {
            auth.redeemLocation(ticket: $0)
        })
    }

    // The athlete may leave the app as soon as Apple's sheet closes. Kept
    // running until the site answers, the app doesn't lose a ticket the
    // site already issued (and spent the token on) to a suspended request.
    private static func sendKeepingAwake(_ request: URLRequest) async -> String? {
        let keepAwake = KeepAwake()
        keepAwake.begin()
        defer { keepAwake.end() }
        return await AppleSignInExchange.send(request)
    }

    private func end() {
        controller = nil
        challenge = nil
        anchor = nil
        navigator = nil
    }
}

/// A background task, ended exactly once: by its owner when the work is
/// done, or by iOS's expiration handler when time runs out first.
@MainActor
private final class KeepAwake {
    private var id = UIBackgroundTaskIdentifier.invalid

    func begin() {
        id = UIApplication.shared.beginBackgroundTask(withName: "Sign in with Apple") { [weak self] in
            MainActor.assumeIsolated { self?.end() }
        }
    }

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}
