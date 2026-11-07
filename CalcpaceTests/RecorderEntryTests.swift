@testable import Calcpace
import XCTest

// The site's Record button (shared/_bottom_nav_record): /record in any of
// its languages, with the profile's unit, opens the recording screen; any
// other path, host or spelling loads as a page. Android's RecorderEntryTest.
final class RecorderEntryTests: XCTestCase {
    private let root = URL(string: "https://calcpace.app")!

    private func visit(_ text: String) -> RecorderEntry.Visit? {
        RecorderEntry.visit(URL(string: text), rootURL: root)
    }

    func testRecordInAnyLanguageWithTheUnit() {
        XCTAssertEqual(visit("https://calcpace.app/record"), .init(locale: nil, unit: nil))
        XCTAssertEqual(visit("https://calcpace.app/record?unit=km"), .init(locale: nil, unit: .km))
        XCTAssertEqual(visit("https://calcpace.app/pt-BR/record?unit=mi"), .init(locale: "pt-BR", unit: .mi))
        XCTAssertEqual(visit("https://calcpace.app/zh-TW/record/"), .init(locale: "zh-TW", unit: nil))
        XCTAssertEqual(visit("https://calcpace.app/no/record#top"), .init(locale: "no", unit: nil))
        XCTAssertEqual(visit("https://calcpace.app/record?unit=furlongs"), .init(locale: nil, unit: nil))
    }

    func testAnythingElseIsAPage() {
        XCTAssertNil(visit("https://calcpace.app/records"))
        XCTAssertNil(visit("https://calcpace.app/record/new"))
        XCTAssertNil(visit("https://calcpace.app/xx/record"))
        XCTAssertNil(visit("https://calcpace.app//record"))
        XCTAssertNil(visit("https://calcpace.app/%72ecord"))
        XCTAssertNil(visit("https://calcpace.app.evil.com/record"))
        XCTAssertNil(visit("https://evil.com/record"))
        XCTAssertNil(visit("http://calcpace.app/record"))
        XCTAssertNil(RecorderEntry.visit(nil, rootURL: root))
    }

    func testTheSiteLocaleNamesItsLocalization() {
        XCTAssertEqual(RecorderLanguage.localization(forSite: "no"), "nb")
        XCTAssertEqual(RecorderLanguage.localization(forSite: "zh-TW"), "zh-Hant")
        XCTAssertEqual(RecorderLanguage.localization(forSite: "pt-BR"), "pt-BR")
    }
}
