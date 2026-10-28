@testable import Calcpace
import XCTest

final class AppUserAgentTests: XCTestCase {
    func testVersionAndBuild() {
        XCTAssertEqual(AppUserAgent.prefix(version: "1.0.0", build: "1"), "Calcpace iOS/1.0.0 (1);")
    }

    func testVersionWithoutBuild() {
        XCTAssertEqual(AppUserAgent.prefix(version: "1.0.0", build: nil), "Calcpace iOS/1.0.0;")
        XCTAssertEqual(AppUserAgent.prefix(version: "1.0.0", build: ""), "Calcpace iOS/1.0.0;")
    }

    func testNoVersionIsStillTheApp() {
        XCTAssertEqual(AppUserAgent.prefix(version: nil, build: "1"), "Calcpace iOS;")
    }

    // Hosted in the app, so the main bundle is the app's own Info.plist.
    func testTheAppBundleSaysItsVersionAndBuild() {
        let prefix = AppUserAgent.prefix()
        XCTAssertTrue(prefix.hasPrefix("Calcpace iOS/"), prefix)
        XCTAssertTrue(prefix.hasSuffix(");"), prefix)
    }
}
