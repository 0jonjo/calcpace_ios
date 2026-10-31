import AuthenticationServices
@testable import Calcpace
import HotwireNative
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
