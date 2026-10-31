@testable import Calcpace
import XCTest

// The Android app's cases (IncomingLinkTest.kt), and what an iPhone does
// with each: ordinary pages only.
final class IncomingLinkTests: XCTestCase {
    private let base = "https://calcpace.app"
    private let ticket = "t3xOHP60nCIs5golfu10UwzzY8aZSDSkcCQ7n4nnUl4"
    private var root: URL { URL(string: base)! }

    private func classify(_ url: String) -> IncomingLink {
        guard let url = URL(string: url) else { return .ignore }
        return IncomingLink.classify(url, rootURL: root)
    }

    private func opens(_ url: String) -> URL? {
        guard let url = URL(string: url) else { return nil }
        return IncomingLink.location(forOutsideLink: url, rootURL: root)
    }

    func testASignInCallbackCarriesItsTicketButIsNeverOpenedFromOutside() {
        XCTAssertEqual(classify("\(base)/app_auth/callback?ticket=\(ticket)"), .signIn(ticket: ticket))
        XCTAssertEqual(classify("\(base)/pt-BR/app_auth/callback?x=1&ticket=\(ticket)"), .signIn(ticket: ticket))
        XCTAssertNil(opens("\(base)/app_auth/callback?ticket=\(ticket)"))
    }

    func testACallbackWithoutAUsableTicketDoesNothing() {
        XCTAssertEqual(classify("\(base)/app_auth/callback"), .ignore)
        XCTAssertEqual(classify("\(base)/app_auth/callback?ticket=short"), .ignore)
        XCTAssertEqual(classify("\(base)/app_auth/callback?ticket=has%20space%20in%20it%20padding"), .ignore)
    }

    // A redeem link from outside must never reach the WebView, whatever
    // ticket and verifier it carries.
    func testRedeemAndStartLinksFromOutsideAreRefused() {
        for url in ["\(base)/app_auth/redeem?ticket=\(ticket)&verifier=x", "\(base)/en/app_auth/redeem?ticket=\(ticket)&verifier=x",
                    "\(base)/app_auth/start?provider=strava&challenge=x", "\(base)/app_auth/google"] {
            XCTAssertEqual(classify(url), .ignore, url)
            XCTAssertNil(opens(url), url)
        }
    }

    // "//app_auth/redeem" reaches Rails' redeem action and would slip past
    // an exact-path check.
    func testNonCanonicalAppAuthLinksAreRefusedToo() {
        for path in ["//app_auth/redeem", "/en//app_auth/redeem", "/app_auth//redeem", "/./app_auth/redeem",
                     "/x/../app_auth/redeem", "/%2e/app_auth/redeem", "/%61pp_auth/redeem", "//app_auth/callback"] {
            XCTAssertEqual(classify("\(base)\(path)?ticket=\(ticket)&verifier=x"), .ignore, path)
            XCTAssertNil(opens("\(base)\(path)?ticket=\(ticket)&verifier=x"), path)
        }
    }

    // What WebKit would read as an app_auth path, or might: ignored.
    func testPathsThatCouldBeReadTwoWaysAreIgnored() {
        for path in ["/x/..//app_auth/redeem", "/app_auth%2Fredeem", "/a/%2e%2e/app_auth/redeem", "/app_auth/x%2F..%2Fredeem",
                     "/x/..//app_auth/callback", "/pt-BR//race-calendar", "/a/../pt-BR"] {
            XCTAssertEqual(classify("\(base)\(path)?ticket=\(ticket)&verifier=x"), .ignore, path)
            XCTAssertNil(opens("\(base)\(path)?ticket=\(ticket)&verifier=x"), path)
        }
    }

    // No browser tab to hand them back to on an iPhone: they stay out of the
    // WebView.
    func testProviderStepsAreRecognisedButNotOpened() {
        let url = "\(base)/en/auth/strava/callback?code=1&state=2"
        XCTAssertEqual(classify(url), .browserTab(URL(string: url)!))
        XCTAssertEqual(classify("\(base)/auth/google/callback"), .browserTab(URL(string: "\(base)/auth/google/callback")!))
        XCTAssertNil(opens(url))
    }

    func testOrdinaryPagesOpenInTheWebView() {
        for url in ["\(base)/pt-BR/race-calendar", "\(base)/authors", "\(base)/", base, "\(base)/pt-BR/activities/12?unit=km"] {
            XCTAssertEqual(classify(url), .web(URL(string: url)!), url)
            XCTAssertEqual(opens(url), URL(string: url)!, url)
        }
    }

    func testOtherSitesSchemesAndPortsAreIgnored() {
        for url in ["http://calcpace.app/pt-BR", "https://evil.example/app_auth/callback?ticket=\(ticket)",
                    "https://calcpace.app:8443/pt-BR", "https://www.calcpace.app/pt-BR",
                    "https://calcpace.app.evil.example/pt-BR", "calcpace://auth?ticket=\(ticket)", "not a url"] {
            XCTAssertEqual(classify(url), .ignore, url)
            XCTAssertNil(opens(url), url)
        }
    }

    // The sign-in's own scheme is the web authentication session's alone;
    // from outside it is nothing.
    func testTheAppsSchemeFromOutsideIsIgnored() {
        for url in ["app.calcpace.ios://app_auth/callback?ticket=\(ticket)", "app.calcpace.ios://calcpace.app/pt-BR",
                    "APP.CALCPACE.IOS://app_auth/callback?ticket=\(ticket)"] {
            XCTAssertEqual(classify(url), .ignore, url)
            XCTAssertNil(opens(url), url)
        }
    }

    func testALocalServerWorksInDebug() {
        let local = URL(string: "http://localhost:3001")!
        XCTAssertEqual(IncomingLink.classify(URL(string: "http://localhost:3001/app_auth/callback?ticket=\(ticket)")!, rootURL: local),
                       .signIn(ticket: ticket))
        XCTAssertEqual(IncomingLink.classify(URL(string: "http://localhost:3001/pt-BR")!, rootURL: local),
                       .web(URL(string: "http://localhost:3001/pt-BR")!))
        XCTAssertEqual(IncomingLink.classify(URL(string: "http://localhost:3000/")!, rootURL: local), .ignore)
    }

    func testTheSiteIsItsSchemeHostAndPort() {
        XCTAssertTrue(IncomingLink.isSite(URL(string: "https://CALCPACE.app/x")!, rootURL: root))
        XCTAssertTrue(IncomingLink.isSite(URL(string: "HTTPS://calcpace.app")!, rootURL: root))
        XCTAssertFalse(IncomingLink.isSite(URL(string: "https://calcpace.app:443/")!, rootURL: root))
        XCTAssertFalse(IncomingLink.isSite(URL(string: "/pt-BR")!, rootURL: root))
    }
}
