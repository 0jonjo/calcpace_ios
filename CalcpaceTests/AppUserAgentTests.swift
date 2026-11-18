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

    // Its own token after the build, so the site's "(build)" reads as before.
    func testTestFlightSaysSo() {
        XCTAssertEqual(AppUserAgent.prefix(version: "1.1.0", build: "7", testFlight: true),
                       "Calcpace iOS/1.1.0 (7); TestFlight;")
        XCTAssertEqual(AppUserAgent.prefix(version: nil, build: nil, testFlight: true), "Calcpace iOS; TestFlight;")
    }

    func testTheReceiptTellsTestFlightFromTheStore() {
        let receipts = URL(fileURLWithPath: "/private/var/containers/Bundle/Application/X/Calcpace.app/StoreKit")
        XCTAssertTrue(AppUserAgent.isTestFlight(receiptURL: receipts.appendingPathComponent("sandboxReceipt")))
        XCTAssertFalse(AppUserAgent.isTestFlight(receiptURL: receipts.appendingPathComponent("receipt")))
        XCTAssertFalse(AppUserAgent.isTestFlight(receiptURL: nil))
    }

    // Hosted in the app, so the main bundle is the app's own Info.plist.
    func testTheAppBundleSaysItsVersionAndBuild() {
        let prefix = AppUserAgent.prefix()
        XCTAssertTrue(prefix.hasPrefix("Calcpace iOS/"), prefix)
        XCTAssertTrue(prefix.hasSuffix(");") || prefix.hasSuffix("); TestFlight;"), prefix)
    }
}
