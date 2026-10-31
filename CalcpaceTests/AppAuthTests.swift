@testable import Calcpace
import XCTest

final class PkceTests: XCTestCase {
    func testChallengeMatchesRfc7636AppendixB() {
        XCTAssertEqual(Pkce.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testVerifierIs43UrlSafeCharacters() throws {
        let verifier = try XCTUnwrap(Pkce.newVerifier())
        XCTAssertEqual(verifier.count, 43)
        XCTAssertNil(verifier.range(of: "[^A-Za-z0-9_-]", options: .regularExpression))
        XCTAssertEqual(Pkce.challenge(for: verifier).count, 43)
    }

    func testVerifiersDoNotRepeat() {
        XCTAssertNotEqual(Pkce.newVerifier(), Pkce.newVerifier())
    }
}

// The Android app's cases (AppAuthPathTest.kt), on the same rules.
final class AppAuthPathsTests: XCTestCase {
    private let site = "https://calcpace.app"
    private let host = "calcpace.app"

    func testSignInButtonsMatchWithOrWithoutLocale() {
        XCTAssertEqual(AppAuthPaths.provider(of: "\(site)/app_auth/google"), "google")
        XCTAssertEqual(AppAuthPaths.provider(of: "\(site)/pt-BR/app_auth/strava"), "strava")
        XCTAssertEqual(AppAuthPaths.provider(of: "\(site)/de/app_auth/google"), "google")
        XCTAssertNil(AppAuthPaths.provider(of: "\(site)/app_auth/facebook"))
        XCTAssertNil(AppAuthPaths.provider(of: "\(site)/xx/app_auth/google"))
    }

    func testOnlyTheExactRedeemAndCallbackPathsCount() {
        XCTAssertTrue(AppAuthPaths.isRedeem("\(site)/app_auth/redeem?ticket=a&verifier=b"))
        XCTAssertTrue(AppAuthPaths.isRedeem("\(site)/es/app_auth/redeem"))
        XCTAssertTrue(AppAuthPaths.isCallback("\(site)/app_auth/callback?ticket=a"))
        for path in ["//app_auth/redeem", "/en//app_auth/redeem", "/app_auth//redeem", "/app_auth/redeem/", "/./app_auth/redeem"] {
            XCTAssertFalse(AppAuthPaths.isRedeem(site + path), path)
        }
        XCTAssertFalse(AppAuthPaths.isCallback("\(site)//app_auth/callback?ticket=a"))
    }

    // Rails collapses "//", the WebView resolves "/./" and "%2e", so every
    // spelling of an app_auth path has to be guarded.
    func testEverySpellingOfAnAppAuthPathIsGuarded() {
        for path in ["/app_auth/redeem", "//app_auth/redeem", "/en//app_auth/redeem", "/app_auth//redeem",
                     "/./app_auth/redeem", "/x/../app_auth/redeem", "/%2e/app_auth/redeem", "/%61pp_auth/redeem",
                     "/APP_AUTH/redeem", "/app_auth/start", "/app_auth/callback", "/pt-BR/app_auth/google"] {
            XCTAssertTrue(AppAuthPaths.isGuarded(site + path + "?ticket=a&verifier=b", host: host), path)
        }
    }

    // What a strict URL parser refuses and a WebView follows. A guard that
    // gives up on what it can't parse would wave them through.
    func testUrlsAStrictParserCannotReadAreStillGuarded() {
        for suffix in ["#%zz", "#|", "&x=|", "&x={}", "&x=%", "#^"] {
            XCTAssertTrue(AppAuthPaths.isGuarded("\(site)/app_auth/redeem?ticket=a&verifier=b\(suffix)", host: host), suffix)
        }
        XCTAssertTrue(AppAuthPaths.isRedeem("\(site)/app_auth/redeem?ticket=a&verifier=b#%zz"))
        XCTAssertTrue(AppAuthPaths.isGuarded("not a url at all", host: host))
        XCTAssertTrue(AppAuthPaths.isGuarded("\(site)/%zz%61pp_auth/redeem", host: host))
        XCTAssertTrue(AppAuthPaths.isGuarded("", host: host))
    }

    // WebKit resolves dot segments before it decodes "%2F" or drops empty
    // segments, and this cleanup doesn't: any path the two could read apart
    // is guarded outright, app_auth in sight or not.
    func testPathsThatCouldBeReadTwoWaysAreGuarded() {
        for path in ["/x/..//app_auth/redeem", "/app_auth%2Fredeem", "/app_auth%2fredeem", "/a/%2e%2e/app_auth/redeem",
                     "/app_auth/x%2F..%2Fredeem", "/x/%2E/app_auth/redeem", "/x/.%2e/app_auth/redeem", "/x/%2e./y",
                     "/a/..", "/./", "/pt-BR//activities", "/a%5Cb", "/a%5cb", "/a/b/.", "//"] {
            XCTAssertTrue(AppAuthPaths.isGuarded(site + path, host: host), path)
        }
        XCTAssertFalse(AppAuthPaths.isGuarded("\(site)/activities/", host: host))
        XCTAssertFalse(AppAuthPaths.isGuarded("https://evil.example//app_auth/redeem", host: host))
        XCTAssertFalse(AppAuthPaths.isGuarded("\(site)/a/...b/c..d/.e?x=//&y=%2F#..", host: host), "dots inside a segment, a query or a fragment are fine")
    }

    // Failing closed must not swallow the site's mailto: and tel: links,
    // which belong to the system's mail and phone apps.
    func testOtherSchemesAreNotTheGuardsBusiness() {
        for url in ["mailto:contact@calcpace.app", "tel:+5584999999999", "sms:123", "geo:0,0", "about:blank"] {
            XCTAssertFalse(AppAuthPaths.isGuarded(url, host: host), url)
        }
    }

    // Browsers read "\" as "/" and drop tab/CR/LF before requesting; the
    // guard must see the same host and path.
    func testRawStringsAreReadTheWayBrowsersReadThem() {
        for url in ["https://calcpace.app\\app_auth\\redeem",
                    "https://calcpace.app\\@evil.example/../app_auth/redeem",
                    "https://calcpace.app/app_\nauth/redeem",
                    "https://calcpace.app/app_\tauth/redeem",
                    "  https://calcpace.app/app_auth/redeem  ",
                    "https://calcpace.app./app_auth/redeem",
                    "HTTPS://CALCPACE.APP/APP_AUTH/REDEEM"] {
            XCTAssertTrue(AppAuthPaths.isGuarded(url, host: host), url)
        }
    }

    func testMalformedEscapesDoNotCrashOrDecodeWrongly() {
        XCTAssertFalse(AppAuthPaths.isGuarded("\(site)/%+1app/%-1", host: host))
        XCTAssertTrue(AppAuthPaths.isGuarded("\(site)/%41PP_AUTH/redeem", host: host))
        XCTAssertFalse(AppAuthPaths.isGuarded("\(site)/news/100%", host: host))
        XCTAssertFalse(AppAuthPaths.isGuarded("\(site)/news/%ff%fe", host: host))
    }

    func testARedeemIsJudgedByWhereItLands() {
        XCTAssertNil(AppAuthPaths.redeemSucceeded("\(site)/app_auth/redeem?ticket=a"))
        XCTAssertEqual(AppAuthPaths.redeemSucceeded("\(site)/pt-BR/session/new"), false)
        XCTAssertEqual(AppAuthPaths.redeemSucceeded("\(site)/session/new"), false)
        XCTAssertEqual(AppAuthPaths.redeemSucceeded("\(site)/"), true)
        XCTAssertEqual(AppAuthPaths.redeemSucceeded("\(site)/profile/new"), true)
        XCTAssertEqual(AppAuthPaths.redeemSucceeded("\(site)/pt-BR/activities"), true)
    }

    func testGuardingIsByHostAloneSoNoSchemeOrPortSlipsPast() {
        XCTAssertTrue(AppAuthPaths.isGuarded("http://calcpace.app/app_auth/redeem", host: host))
        XCTAssertTrue(AppAuthPaths.isGuarded("https://calcpace.app:443/app_auth/redeem", host: host))
        XCTAssertTrue(AppAuthPaths.isGuarded("https://user@CALCPACE.app/app_auth/redeem", host: host))
        XCTAssertFalse(AppAuthPaths.isGuarded("https://evil.example/app_auth/redeem", host: host))
    }

    func testOrdinaryPagesAreNotGuarded() {
        for path in ["/", "/pt-BR", "/auth/google", "/authors", "/pt-BR/race-calendar"] {
            XCTAssertFalse(AppAuthPaths.isGuarded(site + path, host: host), path)
        }
    }

    func testProviderStepsAreRecognisedHoweverSpelled() {
        XCTAssertTrue(AppAuthPaths.isProviderStep("\(site)/auth/google/callback"))
        XCTAssertTrue(AppAuthPaths.isProviderStep("\(site)/en/auth/strava/callback"))
        XCTAssertTrue(AppAuthPaths.isProviderStep("\(site)//en//auth/strava/callback"))
        XCTAssertFalse(AppAuthPaths.isProviderStep("\(site)/authors"))
    }

    // What the route handler is handed: a Foundation URL, whatever it made
    // of the string.
    func testFoundationUrlsAreGuardedToo() throws {
        for path in ["/app_auth/redeem?ticket=a", "//app_auth/redeem", "/%61pp_auth/redeem", "/app_auth/redeem#%7C"] {
            let url = try XCTUnwrap(URL(string: site + path), path)
            XCTAssertTrue(AppAuthPaths.isGuarded(url.absoluteString, host: url.host), path)
        }
    }
}

final class AppAuthTests: XCTestCase {
    private let root = URL(string: "https://calcpace.app")!
    private let ticket = "t3xOHP60nCIs5golfu10UwzzY8aZSDSkcCQ7n4nnUl4"
    private var defaults: UserDefaults!
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)
    private var auth: AppAuth!

    override func setUp() {
        defaults = UserDefaults(suiteName: "AppAuthTests")!
        defaults.removePersistentDomain(forName: "AppAuthTests")
        auth = AppAuth(rootURL: root, defaults: defaults) { [unowned self] in self.clock }
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: "AppAuthTests")
    }

    private func query(_ url: URL) -> [String: String] {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
    }

    private func verifier(of redeem: URL) -> String {
        query(redeem)["verifier"] ?? ""
    }

    func testBeginOpensTheStartPageWithAChallengeForIos() throws {
        let start = try XCTUnwrap(auth.begin(provider: "strava"))
        XCTAssertEqual(start.scheme, "https")
        XCTAssertEqual(start.host, "calcpace.app")
        XCTAssertEqual(start.path, "/app_auth/start")
        let items = query(start)
        XCTAssertEqual(items["provider"], "strava")
        XCTAssertEqual(items["platform"], "ios")
        XCTAssertEqual(items["challenge"]?.count, 43)

        // The challenge is the verifier's, which only the redeem reveals.
        let redeem = try XCTUnwrap(auth.redeemLocation(ticket: ticket))
        XCTAssertEqual(Pkce.challenge(for: verifier(of: redeem)), items["challenge"])
    }

    func testOnlyGoogleAndStrava() {
        XCTAssertNotNil(auth.begin(provider: "google"))
        XCTAssertNil(auth.begin(provider: "facebook"))
        XCTAssertNil(auth.begin(provider: ""))
        XCTAssertNil(auth.begin(provider: "Google"))
    }

    func testEachSignInGetsItsOwnVerifier() throws {
        let first = try XCTUnwrap(auth.begin(provider: "google"))
        let second = try XCTUnwrap(auth.begin(provider: "google"))
        XCTAssertNotEqual(query(first)["challenge"], query(second)["challenge"])
        let redeem = try XCTUnwrap(auth.redeemLocation(ticket: ticket))
        XCTAssertEqual(Pkce.challenge(for: verifier(of: redeem)), query(second)["challenge"])
    }

    func testTheCallbackIsTheSitesExactAddress() {
        XCTAssertEqual(AppAuth.ticket(fromCallback: URL(string: "app.calcpace.ios://app_auth/callback?ticket=\(ticket)")!), ticket)
        XCTAssertEqual(AppAuth.ticket(fromCallback: URL(string: "APP.CALCPACE.IOS://app_auth/callback?ticket=\(ticket)")!), ticket)
    }

    func testAnythingElseOnTheSchemeHasNoTicket() {
        for url in [
            "app.calcpace.ios://app_auth/callback",
            "app.calcpace.ios://app_auth/callback?ticket=short",
            "app.calcpace.ios://app_auth/callback?ticket=\(ticket)x",
            "app.calcpace.ios://app_auth/callback?ticket=\(ticket)&ticket=\(ticket)",
            "app.calcpace.ios://app_auth/callback?ticket=",
            "app.calcpace.ios://app_auth/callback/?ticket=\(ticket)",
            "app.calcpace.ios://app_auth//callback?ticket=\(ticket)",
            "app.calcpace.ios://app_auth/callbac%6B?ticket=\(ticket)",
            "app.calcpace.ios://app_auth/redeem?ticket=\(ticket)",
            "app.calcpace.ios://evil/callback?ticket=\(ticket)",
            "app.calcpace.ios://user@app_auth/callback?ticket=\(ticket)",
            "app.calcpace.ios://app_auth:1/callback?ticket=\(ticket)",
            "app.calcpace.ios:/app_auth/callback?ticket=\(ticket)",
            "calcpace://app_auth/callback?ticket=\(ticket)",
            "https://calcpace.app/app_auth/callback?ticket=\(ticket)",
            "app.calcpace.ios.evil://app_auth/callback?ticket=\(ticket)"
        ] {
            guard let callback = URL(string: url) else { continue }
            XCTAssertNil(AppAuth.ticket(fromCallback: callback), url)
        }
    }

    func testARedeemNeedsASignInOfOurs() {
        XCTAssertNil(auth.redeemLocation(ticket: ticket))
        XCTAssertNotNil(auth.begin(provider: "google"))
        XCTAssertNil(auth.redeemLocation(ticket: "short"))
        XCTAssertNil(auth.redeemLocation(ticket: "\(ticket)&verifier=x"))
    }

    func testTheRedeemCarriesTheTicketAndVerifier() throws {
        XCTAssertNotNil(auth.begin(provider: "google"))
        let redeem = try XCTUnwrap(auth.redeemLocation(ticket: ticket))
        XCTAssertEqual(redeem.scheme, "https")
        XCTAssertEqual(redeem.host, "calcpace.app")
        XCTAssertEqual(redeem.path, "/app_auth/redeem")
        XCTAssertEqual(query(redeem)["ticket"], ticket)
        XCTAssertEqual(verifier(of: redeem).count, 43)
        XCTAssertTrue(AppAuthPaths.isRedeem(redeem.absoluteString))
    }

    // As long as the site keeps the challenge bound, and no longer.
    func testTheVerifierExpiresAfterThirtyMinutes() throws {
        XCTAssertNotNil(auth.begin(provider: "strava"))
        clock += 30 * 60
        XCTAssertNotNil(auth.redeemLocation(ticket: ticket))

        XCTAssertNotNil(auth.begin(provider: "strava"))
        clock += 30 * 60 + 1
        XCTAssertNil(auth.redeemLocation(ticket: ticket))
        clock -= 30 * 60
        XCTAssertNil(auth.redeemLocation(ticket: ticket), "an expired verifier is gone")
    }

    func testAClockThatWentBackIsNotFresh() {
        XCTAssertNotNil(auth.begin(provider: "strava"))
        clock -= 60
        XCTAssertNil(auth.redeemLocation(ticket: ticket))
    }

    // A sign-in started over forgets the redeem the last one built and was
    // waiting on.
    func testANewSignInForgetsTheLastOnesRedeem() throws {
        XCTAssertNotNil(auth.begin(provider: "google"))
        let redeem = try XCTUnwrap(auth.redeemLocation(ticket: ticket))
        XCTAssertNotNil(auth.begin(provider: "strava"))
        XCTAssertFalse(auth.takeExpectedRedeem(redeem))

        auth.visitCompleted(URL(string: "https://calcpace.app/")!)
        XCTAssertNotNil(auth.redeemLocation(ticket: ticket), "nothing was in flight to judge")
    }

    func testAFailedVisitEndsTheRedeemAndKeepsTheVerifier() {
        XCTAssertNotNil(auth.begin(provider: "google"))
        XCTAssertNotNil(auth.redeemLocation(ticket: ticket))
        auth.visitFailed()
        auth.visitCompleted(URL(string: "https://calcpace.app/")!)
        XCTAssertNotNil(auth.redeemLocation(ticket: ticket), "the landing after a failure isn't the redeem's")
    }

    func testTheExpectedRedeemIsTakenOnceAndExactly() throws {
        XCTAssertNotNil(auth.begin(provider: "google"))
        let redeem = try XCTUnwrap(auth.redeemLocation(ticket: ticket))
        XCTAssertFalse(auth.takeExpectedRedeem(URL(string: redeem.absoluteString + "&x=1")!))
        XCTAssertFalse(auth.takeExpectedRedeem(URL(string: "https://calcpace.app/app_auth/redeem?ticket=\(ticket)&verifier=x")!))
        XCTAssertTrue(auth.takeExpectedRedeem(redeem))
        XCTAssertFalse(auth.takeExpectedRedeem(redeem), "once")
    }

    func testNoRedeemIsExpectedBeforeOneIsBuilt() {
        XCTAssertFalse(auth.takeExpectedRedeem(URL(string: "https://calcpace.app/app_auth/redeem?ticket=\(ticket)&verifier=x")!))
        XCTAssertNotNil(auth.begin(provider: "google"))
        XCTAssertFalse(auth.takeExpectedRedeem(URL(string: "https://calcpace.app/app_auth/redeem?ticket=\(ticket)&verifier=x")!))
    }

    // A bogus callback must not wipe the verifier before the real one arrives.
    func testACallbackNeverSpendsTheVerifier() throws {
        XCTAssertNotNil(auth.begin(provider: "google"))
        XCTAssertNil(AppAuth.ticket(fromCallback: URL(string: "app.calcpace.ios://app_auth/callback?ticket=bogus")!))
        XCTAssertNotNil(AppAuth.ticket(fromCallback: URL(string: "app.calcpace.ios://app_auth/callback?ticket=\(ticket)")!))
        XCTAssertNotNil(auth.redeemLocation(ticket: ticket))
        XCTAssertNotNil(auth.redeemLocation(ticket: ticket))
    }

    func testAGoodRedeemSpendsTheVerifier() {
        XCTAssertNotNil(auth.begin(provider: "google"))
        XCTAssertNotNil(auth.redeemLocation(ticket: ticket))
        auth.visitCompleted(URL(string: "https://calcpace.app/app_auth/redeem?ticket=\(ticket)")!)
        XCTAssertNotNil(auth.redeemLocation(ticket: ticket), "still under app_auth: not judged yet")

        auth.visitCompleted(URL(string: "https://calcpace.app/pt-BR/activities")!)
        XCTAssertNil(auth.redeemLocation(ticket: ticket))
    }

    func testAFailedRedeemKeepsTheVerifier() {
        XCTAssertNotNil(auth.begin(provider: "google"))
        XCTAssertNotNil(auth.redeemLocation(ticket: ticket))
        auth.visitCompleted(URL(string: "https://calcpace.app/session/new")!)
        XCTAssertNotNil(auth.redeemLocation(ticket: ticket))
    }

    // Only the first landing after a redeem counts; ordinary visits with no
    // redeem in flight leave the verifier alone.
    func testOnlyTheVisitAfterARedeemIsJudged() {
        XCTAssertNotNil(auth.begin(provider: "google"))
        auth.visitCompleted(URL(string: "https://calcpace.app/")!)
        XCTAssertNotNil(auth.redeemLocation(ticket: ticket))

        auth.visitCompleted(URL(string: "https://calcpace.app/pt-BR/session/new")!)
        auth.visitCompleted(URL(string: "https://calcpace.app/")!)
        XCTAssertNotNil(auth.redeemLocation(ticket: ticket), "the failure was the judged visit")
    }
}
