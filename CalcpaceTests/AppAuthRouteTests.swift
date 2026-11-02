@testable import Calcpace
import HotwireNative
import UIKit
import XCTest

final class AppAuthRouteTests: XCTestCase {
    private let root = URL(string: "https://calcpace.app")!
    private let ticket = "t3xOHP60nCIs5golfu10UwzzY8aZSDSkcCQ7n4nnUl4"
    private var configuration: Navigator.Configuration { .init(name: "main", startLocation: root) }
    private var defaults: UserDefaults!
    private var auth: AppAuth!
    private var signIns: [String] = []
    private var handler: AppAuthRouteDecisionHandler!
    private let navigator = StubNavigator()

    override func setUp() {
        defaults = UserDefaults(suiteName: "AppAuthRouteTests")!
        defaults.removePersistentDomain(forName: "AppAuthRouteTests")
        auth = AppAuth(rootURL: root, defaults: defaults)
        signIns = []
        handler = AppAuthRouteDecisionHandler(auth: auth) { [unowned self] provider, _ in self.signIns.append(provider) }
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: "AppAuthRouteTests")
    }

    private func proposal(_ url: URL) -> VisitProposal {
        VisitProposal(url: url, options: VisitOptions())
    }

    private func matches(_ url: String) -> Bool {
        handler.matches(proposal: proposal(URL(string: url)!), configuration: configuration)
    }

    private func decide(_ url: URL) -> Router.Decision {
        handler.handle(proposal: proposal(url), configuration: configuration, navigator: navigator)
    }

    private func decide(_ url: String) -> Router.Decision {
        decide(URL(string: url)!)
    }

    func testTheExpectedRedeemNavigatesOnceAndOnlyExactly() throws {
        XCTAssertNotNil(auth.begin(provider: "google"))
        let redeem = try XCTUnwrap(auth.redeemLocation(ticket: ticket))
        XCTAssertTrue(matches(redeem.absoluteString))

        XCTAssertEqual(decide(redeem.absoluteString + "&x=1"), .cancel)
        XCTAssertEqual(decide("https://calcpace.app/app_auth/redeem?ticket=\(ticket)&verifier=x"), .cancel)
        XCTAssertEqual(decide(redeem), .navigate)
        XCTAssertEqual(decide(redeem), .cancel, "once")
    }

    func testARedeemNobodyBuiltIsCancelled() {
        XCTAssertEqual(decide("https://calcpace.app/app_auth/redeem?ticket=\(ticket)&verifier=x"), .cancel)
        XCTAssertEqual(decide("https://calcpace.app/pt-BR/app_auth/redeem?ticket=\(ticket)&verifier=x"), .cancel)
    }

    func testTheSignInButtonsOpenTheBrowserInstead() {
        XCTAssertTrue(matches("https://calcpace.app/app_auth/google"))
        XCTAssertEqual(decide("https://calcpace.app/app_auth/google"), .cancel)
        XCTAssertEqual(decide("https://calcpace.app/pt-BR/app_auth/strava"), .cancel)
        XCTAssertEqual(signIns, ["google", "strava"])
    }

    func testEverythingElseUnderAppAuthIsCancelled() {
        for url in ["https://calcpace.app/app_auth/start?provider=google&challenge=x", "https://calcpace.app/app_auth/callback?ticket=\(ticket)",
                    "https://calcpace.app/app_auth/facebook", "https://calcpace.app//app_auth/google", "https://calcpace.app/x/..//app_auth/redeem",
                    "http://calcpace.app/app_auth/google", "https://calcpace.app:8443/app_auth/google"] {
            XCTAssertTrue(matches(url), url)
            XCTAssertEqual(decide(url), .cancel, url)
        }
        XCTAssertEqual(signIns, [], "only the exact button paths on the site open the browser")
    }

    func testOtherHostsAndOrdinaryPagesAreNotItsBusiness() {
        for url in ["https://evil.example/app_auth/redeem?ticket=\(ticket)&verifier=x", "https://evil.example/app_auth/google",
                    "https://calcpace.app/", "https://calcpace.app/pt-BR/activities", "https://calcpace.app/auth/google/callback"] {
            XCTAssertFalse(matches(url), url)
        }
    }

    // First, before the CSV export and in-app navigation can claim an
    // app_auth URL.
    func testItIsTheFirstRouteHandler() {
        let handlers = AppDelegate.routeDecisionHandlers
        XCTAssertTrue(handlers.first is AppAuthRouteDecisionHandler)
        XCTAssertEqual(handlers.map(\.name).prefix(3), ["app-auth", "csv-export", "app-navigation"])
    }
}

/// Enough of a Navigator for the route handler, which only hands it on to
/// the browser, stubbed here: nothing reads its screens.
private final class StubNavigator: Navigating {
    var rootViewController: UINavigationController { fatalError("not used") }
    var modalRootViewController: UINavigationController { fatalError("not used") }
    var activeNavigationController: UINavigationController { fatalError("not used") }

    func pop(animated: Bool) {}
    func clearAll(animated: Bool) {}
    func reload() {}
    func route(_ url: URL, options: VisitOptions?, parameters: [String: Any]?) {}
    func route(_ proposal: VisitProposal) {}
}
