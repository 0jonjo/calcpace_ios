@testable import Calcpace
import XCTest

final class ScreenTitleTests: XCTestCase {
    func testDropsTheSiteName() {
        XCTAssertEqual(ScreenTitle.short("Settings — Calcpace"), "Settings")
        XCTAssertEqual(ScreenTitle.short("Race Time Predictor - Goals for Every Distance | Calcpace"), "Race Time Predictor - Goals for Every Distance")
        XCTAssertEqual(ScreenTitle.short("Pace chart - Calcpace"), "Pace chart")
    }

    func testKeepsATitleWithoutIt() {
        XCTAssertEqual(ScreenTitle.short("Morning run"), "Morning run")
        XCTAssertEqual(ScreenTitle.short("Calcpace"), "Calcpace")
        XCTAssertEqual(ScreenTitle.short("Calcpace for runners"), "Calcpace for runners")
    }

    func testNoTitleIsNoTitle() {
        XCTAssertNil(ScreenTitle.short(nil))
        XCTAssertNil(ScreenTitle.short("  "))
    }
}
