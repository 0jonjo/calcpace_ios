import AuthenticationServices
@testable import Calcpace
import HotwireNative
import UIKit
import XCTest

@MainActor
final class AppleSignInTests: XCTestCase {
    // Closing the sheet leaves the app where it was; any other error from
    // Apple (no entitlement yet, no Apple Account, a failed request) shows
    // the sign-in page's error.
    func testOnlyClosingTheSheetIsACancel() {
        XCTAssertTrue(AppleSignIn.isCancel(ASAuthorizationError(.canceled)))
        XCTAssertTrue(AppleSignIn.isCancel(NSError(domain: ASAuthorizationError.errorDomain, code: ASAuthorizationError.Code.canceled.rawValue)))
        for error: Error in [ASAuthorizationError(.unknown), ASAuthorizationError(.failed), ASAuthorizationError(.invalidResponse),
                             ASAuthorizationError(.notHandled), URLError(.timedOut),
                             NSError(domain: "other", code: ASAuthorizationError.Code.canceled.rawValue)] {
            XCTAssertFalse(AppleSignIn.isCancel(error), String(describing: error))
        }
    }

    // The site compares the token's nonce claim with the challenge as
    // sent: hashing it here would fail every sign-in.
    func testTheRequestAsksOnlyForTheEmailWithTheRawChallengeAsNonce() {
        let challenge = "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
        let request = AppleSignIn.authorizationRequest(challenge: challenge)
        XCTAssertEqual(request.nonce, challenge)
        XCTAssertEqual(request.requestedScopes, [.email])
    }

    func testTheButtonsPathSegmentIsApple() {
        XCTAssertEqual(AppleSignIn.provider, "apple")
        XCTAssertEqual(AppAuthPaths.provider(of: "https://calcpace.app/app_auth/\(AppleSignIn.provider)"), AppleSignIn.provider)
    }

    func testTheComponentIsNamedForTheSite() {
        XCTAssertEqual(AppleSignInComponent.name, "apple-sign-in")
    }

    // Hosted in the app, so AppDelegate has registered its components: the
    // site shows the social sign-in buttons only when the user agent lists
    // apple-sign-in.
    func testTheUserAgentListsTheComponent() {
        let agent = Hotwire.config.userAgent
        XCTAssertTrue(agent.hasPrefix(AppUserAgent.prefix()), agent)
        XCTAssertTrue(agent.hasSuffix("bridge-components: [share-image apple-health push apple-sign-in]"), agent)
    }
}

// The sign-in's state, with a stand-in for Apple's sheet: nothing is ever
// presented. A completed authorization can't be made outside Apple's sheet
// (ASAuthorization has no public initializer), so success is left to
// AppleSignInExchangeTests.
@MainActor
final class AppleSignInStateTests: XCTestCase {
    private let root = URL(string: "https://calcpace.app")!
    private let ticket = "t3xOHP60nCIs5golfu10UwzzY8aZSDSkcCQ7n4nnUl4"
    private lazy var defaults: UserDefaults = {
        let defaults = UserDefaults(suiteName: "AppleSignInStateTests")!
        defaults.removePersistentDomain(forName: "AppleSignInStateTests")
        return defaults
    }()
    private lazy var auth = AppAuth(rootURL: root, defaults: defaults)
    private lazy var navigator = RecordingNavigator()
    private var performed: [ASAuthorizationController] = []
    private var browserBusy = false

    private func makeSignIn() -> AppleSignIn {
        AppleSignIn(auth: auth, rootURL: root, otherIsBusy: { [unowned self] in self.browserBusy }) { [unowned self] controller in
            self.performed.append(controller)
        }
    }

    func testItStartsOneAtATime() {
        let signIn = makeSignIn()
        signIn.signIn(navigator: navigator)
        XCTAssertTrue(signIn.isBusy)
        XCTAssertEqual(performed.count, 1)
        XCTAssertNotNil(auth.redeemLocation(ticket: ticket), "a verifier is kept")

        signIn.signIn(navigator: navigator)
        XCTAssertEqual(performed.count, 1, "a second tap is ignored")
    }

    func testItWontStartWhileTheBrowserSignInIsOpen() {
        browserBusy = true
        let signIn = makeSignIn()
        signIn.signIn(navigator: navigator)
        XCTAssertFalse(signIn.isBusy)
        XCTAssertEqual(performed.count, 0)
        XCTAssertNil(auth.redeemLocation(ticket: ticket), "the browser's verifier is left alone")
    }

    func testTheBrowserWontStartWhileSignInWithAppleIsUnderWay() {
        let apple = makeSignIn()
        apple.signIn(navigator: navigator)
        XCTAssertTrue(apple.isBusy)
        let challengeKept = auth.redeemLocation(ticket: ticket)

        let browser = AppAuthBrowser(auth: auth) { apple.isBusy }
        browser.signIn(with: "google", navigator: navigator)
        XCTAssertFalse(browser.isBusy)
        XCTAssertEqual(auth.redeemLocation(ticket: ticket)?.absoluteString, challengeKept?.absoluteString, "Apple's verifier is left alone")
    }

    func testClosingTheSheetDoesNothing() throws {
        let signIn = makeSignIn()
        signIn.signIn(navigator: navigator)
        let controller = try XCTUnwrap(performed.first)
        signIn.authorizationController(controller: controller, didCompleteWithError: ASAuthorizationError(.canceled))
        XCTAssertFalse(signIn.isBusy)
        XCTAssertEqual(navigator.routes, [])

        signIn.signIn(navigator: navigator)
        XCTAssertEqual(performed.count, 2, "free for the next tap")
    }

    func testAnyOtherErrorShowsTheFailedPage() throws {
        let signIn = makeSignIn()
        signIn.signIn(navigator: navigator)
        let controller = try XCTUnwrap(performed.first)
        signIn.authorizationController(controller: controller, didCompleteWithError: ASAuthorizationError(.unknown))
        XCTAssertFalse(signIn.isBusy)
        XCTAssertEqual(navigator.routes, [URL(string: "https://calcpace.app/app_auth/failed")!])
    }

    func testCallbacksFromAnotherControllerAreIgnored() throws {
        let signIn = makeSignIn()
        signIn.signIn(navigator: navigator)
        let stranger = ASAuthorizationController(authorizationRequests: [AppleSignIn.authorizationRequest(challenge: "x")])
        signIn.authorizationController(controller: stranger, didCompleteWithError: ASAuthorizationError(.unknown))
        signIn.authorizationController(controller: stranger, didCompleteWithError: ASAuthorizationError(.canceled))
        XCTAssertTrue(signIn.isBusy)
        XCTAssertEqual(navigator.routes, [])

        let controller = try XCTUnwrap(performed.first)
        signIn.authorizationController(controller: controller, didCompleteWithError: ASAuthorizationError(.canceled))
        signIn.authorizationController(controller: controller, didCompleteWithError: ASAuthorizationError(.unknown))
        XCTAssertEqual(navigator.routes, [], "a finished sign-in's late callback is ignored too")
    }

    func testNoWindowNoSheet() {
        let signIn = makeSignIn()
        signIn.signIn(navigator: RecordingNavigator(inWindow: false))
        XCTAssertFalse(signIn.isBusy)
        XCTAssertEqual(performed.count, 0)
    }
}

/// A Navigator whose root sits in a window, as the sheet needs, and which
/// records where it was sent.
@MainActor
private final class RecordingNavigator: Navigating {
    let rootViewController = UINavigationController()
    var modalRootViewController: UINavigationController { rootViewController }
    var activeNavigationController: UINavigationController { rootViewController }
    private(set) var routes: [URL] = []
    private var window: UIWindow?

    init(inWindow: Bool = true) {
        guard inWindow else { return }
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = rootViewController
        window.isHidden = false
        self.window = window
    }

    func pop(animated: Bool) {}
    func clearAll(animated: Bool) {}
    func reload() {}
    func route(_ url: URL, options: VisitOptions?, parameters: [String: Any]?) { routes.append(url) }
    func route(_ proposal: VisitProposal) { routes.append(proposal.url) }
}
