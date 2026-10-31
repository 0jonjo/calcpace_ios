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
/// Inert until the Apple account provisions the Sign in with Apple
/// entitlement: until then the sheet fails, and the WebView lands on
/// /app_auth/failed.
@MainActor
final class AppleSignIn: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    static let shared = AppleSignIn()

    /// The button's path segment, /app_auth/apple (`AppAuthPaths.provider`).
    static let provider = "apple"

    private var controller: ASAuthorizationController?
    private var challenge: String?
    private var anchor: UIWindow?
    private weak var navigator: Navigating?

    var isBusy: Bool { controller != nil }

    func signIn(navigator: Navigating) {
        // The sheet needs a window on screen to come up from.
        guard controller == nil, !AppAuthBrowser.shared.isBusy,
              let window = navigator.rootViewController.viewIfLoaded?.window,
              let challenge = AppAuth.shared.beginApple()
        else { return }

        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = [.email]
        request.nonce = challenge

        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.presentationContextProvider = self

        self.controller = controller
        self.challenge = challenge
        self.anchor = window
        self.navigator = navigator
        controller.performRequests()
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
                  rootURL: AppDelegate.rootURL,
                  userAgent: "\(AppUserAgent.prefix()) (Sign in with Apple)"
              )
        else { return finish(controller, ticket: nil) }

        Task { [weak self] in
            let ticket = await AppleSignInExchange.send(request)
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
        navigator?.route(AppleSignInExchange.destination(ticket: ticket, rootURL: AppDelegate.rootURL) {
            AppAuth.shared.redeemLocation(ticket: $0)
        })
    }

    private func end() {
        controller = nil
        challenge = nil
        anchor = nil
        navigator = nil
    }
}
