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
}
