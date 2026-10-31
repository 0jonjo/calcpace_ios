@testable import Calcpace
import HotwireNative
import XCTest

// The copy bundled with the app, used until the site's (calcpace_web's
// ConfigurationsController#ios_v1, from the same TabRoots list) arrives.
final class PathConfigurationTests: XCTestCase {
    private var configuration: PathConfiguration!

    override func setUpWithError() throws {
        let url = try XCTUnwrap(Bundle(for: WebViewController.self).url(forResource: "path-configuration", withExtension: "json"))
        configuration = PathConfiguration(sources: [.file(url)])
    }

    func testTheFrontPageAndTheTabsAreRootsInEveryLanguage() {
        for path in ["", "/", "/activities", "/zones", "/result", "/race-calendar", "/guides", "/converter", "/registration/new"] {
            for locale in ["", "/pt-BR", "/en", "/zh-TW", "/ru"] {
                let properties = configuration.properties(for: locale + path)
                XCTAssertTrue(properties.tabRoot, locale + path)
                XCTAssertEqual(properties.presentation, .replaceRoot, locale + path)
                XCTAssertFalse(properties.animated, locale + path)
            }
        }
    }

    // The URL's query rides along when Hotwire matches ("/result?time=…").
    func testAQueryIsStillTheTab() {
        XCTAssertTrue(configuration.properties(for: "/result?distance=10k&time=50-00").tabRoot)
        XCTAssertTrue(configuration.properties(for: "/pt-BR/activities/?page=2").tabRoot)
    }

    func testEverythingElseIsPushedWithPullToRefresh() {
        for path in ["/activities/new", "/activities/12", "/pt-BR/activities/12", "/result/10k/50-00", "/guides/pace-chart",
                     "/calculator", "/settings", "/session/new", "/xx/activities", "/activities.csv"] {
            let properties = configuration.properties(for: path)
            XCTAssertFalse(properties.tabRoot, path)
            XCTAssertEqual(properties.presentation, .default, path)
            XCTAssertEqual(properties.context, .default, path)
            XCTAssertTrue(properties.pullToRefreshEnabled, path)
            XCTAssertTrue(properties.animated, path)
        }
    }

    // The sign-in hand-off, as in the Android app's configuration: nothing
    // under app_auth is pulled to refresh, and the redeem replaces the whole
    // stack, so Back after signing in doesn't return to the signed-out
    // sign-in page, and a recreated WebView doesn't route a spent redeem.
    func testTheSignInHandOff() {
        for locale in ["", "/pt-BR", "/zh-TW"] {
            let redeem = configuration.properties(for: locale + "/app_auth/redeem?ticket=a&verifier=b")
            XCTAssertEqual(redeem.presentation, .replaceRoot, locale)
            XCTAssertFalse(redeem.pullToRefreshEnabled, locale)
            XCTAssertFalse(redeem.tabRoot, locale)
            XCTAssertEqual(configuration.properties(for: locale + "/app_auth/redeem").presentation, .replaceRoot, locale)

            let other = configuration.properties(for: locale + "/app_auth/google")
            XCTAssertFalse(other.pullToRefreshEnabled, locale)
            XCTAssertEqual(other.presentation, .default, locale)
        }
        XCTAssertEqual(configuration.properties(for: "/app_auth/redeemx").presentation, .default)

        // A Sign in with Apple that got no ticket: the sign-in page with the
        // site's error takes the place of the one the athlete tapped from,
        // rather than stacking a second one on it. The app builds only this
        // spelling (AppAuthPaths.isFailed).
        let failed = configuration.properties(for: "/app_auth/failed")
        XCTAssertEqual(failed.presentation, .replace)
        XCTAssertFalse(failed.pullToRefreshEnabled)
        XCTAssertFalse(failed.tabRoot)
        XCTAssertEqual(configuration.properties(for: URL(string: "https://calcpace.app/app_auth/failed")!).presentation, .replace)
        for path in ["/app_auth/failed?x=1", "/app_auth/failed/", "/pt-BR/app_auth/failed", "/app_auth/failedx"] {
            XCTAssertEqual(configuration.properties(for: path).presentation, .default, path)
        }
        XCTAssertTrue(configuration.properties(for: "/guides/app_auth/").pullToRefreshEnabled)
    }
}
