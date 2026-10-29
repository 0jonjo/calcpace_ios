@testable import Calcpace
import XCTest

// The Android app's cases (CsvExportTest.kt), on the same rules.
final class CsvExportTests: XCTestCase {
    private let base = "https://calcpace.app"
    private var root: URL { URL(string: base)! }

    private func isExport(_ location: String) -> Bool {
        guard let url = URL(string: location) else { return false }
        return CsvExport.isExport(url, rootURL: root)
    }

    func testTheExportInAnyLocaleWithItsFilters() {
        for path in ["/activities/export", "/pt-BR/activities/export", "/en/activities/export", "/zh-TW/activities/export",
                     "/activities/export/", "/activities/export.csv", "/pt-BR/activities/export.csv",
                     "/pt-BR/activities/export?unit=km", "/activities/export?unit=mi&period=month",
                     "/pt-BR/activities/export?unit=km&period=custom&date_from=2026-01-01&date_to=2026-10-18",
                     "/activities/export#top", "/activities/export?"] {
            XCTAssertTrue(isExport(base + path), path)
        }
        XCTAssertTrue(CsvExport.isExport(URL(string: base + "/pt-BR/activities/export?unit=km")!, rootURL: URL(string: base + "/")!))
    }

    func testOtherRoutesUnderOrAroundTheExportAreNot() {
        for path in ["/activities", "/activities/", "/activities/123", "/pt-BR/activities/123", "/activities/export.html",
                     "/activities/export.json", "/activities/exports", "/activities/export/1", "/activities/export//",
                     "/activities//export", "//activities/export", "/activities/%65xport", "/activities/Export",
                     "/xx/activities/export", "/pt-br/activities/export", "/pt-BR/pt-BR/activities/export",
                     "/account/activities/export", "/export", "/", ""] {
            XCTAssertFalse(isExport(base + path), path)
        }
    }

    func testOtherHostsSchemesAndPortsAreNot() {
        for location in ["https://evil.example/activities/export", "https://calcpace.app.evil.example/activities/export",
                         "https://calcpace.app:8443/activities/export", "http://calcpace.app/activities/export",
                         "https://www.calcpace.app/activities/export",
                         "https://evil.example/?u=https://calcpace.app/activities/export", "/activities/export"] {
            XCTAssertFalse(isExport(location), location)
        }
    }

    func testTheServersFilenameAsRailsSendsIt() {
        XCTAssertEqual(
            CsvExport.filename("attachment; filename=\"calcpace_activities_2026-10-18.csv\"; filename*=UTF-8''calcpace_activities_2026-10-18.csv"),
            "calcpace_activities_2026-10-18.csv"
        )
    }

    func testEitherFormOnItsOwn() {
        XCTAssertEqual(CsvExport.filename("attachment; filename=\"a.csv\""), "a.csv")
        XCTAssertEqual(CsvExport.filename("attachment; filename=a.csv"), "a.csv")
        XCTAssertEqual(CsvExport.filename("attachment;filename=a.csv;"), "a.csv")
        XCTAssertEqual(CsvExport.filename("attachment; filename*=UTF-8''a.csv"), "a.csv")
        XCTAssertEqual(CsvExport.filename("ATTACHMENT; FILENAME=\"a.csv\""), "a.csv")
    }

    func testAValidPlainNameWinsOverAnInvalidExtendedOne() {
        XCTAssertEqual(
            CsvExport.filename("attachment; filename=\"calcpace_activities.csv\"; filename*=UTF-8''corridas%20%C3%A9.csv"),
            "calcpace_activities.csv"
        )
    }

    func testAnythingButAPlainCsvNameFallsBack() {
        let headers: [String?] = [
            nil, "", "attachment", "inline", "attachment; filename=\"\"", "attachment; filename=\"../../evil.csv\"",
            "attachment; filename=\"dir/a.csv\"", "attachment; filename=\".hidden.csv\"", "attachment; filename=\"a.html\"",
            "attachment; filename=\"a.csv.exe\"", "attachment; filename=\"a b.csv\"", "attachment; filename=\"a\\\\b.csv\"",
            "attachment; filename*=UTF-8''%2E%2E%2Fa.csv", "attachment; filename=\"\(String(repeating: "a", count: 80)).csv\"",
            "attachment; xfilename=\"a.csv\"",
        ]
        for header in headers {
            XCTAssertEqual(CsvExport.filename(header), CsvExport.fallbackFilename, String(describing: header))
        }
    }

    func testOnlyACsvIsShared() {
        for type in ["text/csv", "text/csv; charset=utf-8", "TEXT/CSV", " text/csv ;charset=utf-8"] {
            XCTAssertTrue(CsvExport.isCSV(type), type)
        }
        for type: String? in [nil, "", "text/html", "text/html; charset=utf-8", "application/json", "text/csvx", "text/plain"] {
            XCTAssertFalse(CsvExport.isCSV(type), String(describing: type))
        }
    }

    func testTheSessionCookieGoesOnlyToItsOwnSite() {
        XCTAssertTrue(CsvExport.cookie(for: "calcpace.app", isSentTo: "calcpace.app"))
        XCTAssertTrue(CsvExport.cookie(for: ".calcpace.app", isSentTo: "calcpace.app"))
        XCTAssertTrue(CsvExport.cookie(for: ".calcpace.app", isSentTo: "www.calcpace.app"))
        XCTAssertFalse(CsvExport.cookie(for: "calcpace.app", isSentTo: "evilcalcpace.app"))
        XCTAssertFalse(CsvExport.cookie(for: "evil.example", isSentTo: "calcpace.app"))
        XCTAssertFalse(CsvExport.cookie(for: "", isSentTo: "calcpace.app"))
        XCTAssertFalse(CsvExport.cookie(for: "calcpace.app", isSentTo: nil))
    }
}

// A string for every language, and the same key in each (Resources/*.lproj).
final class LocalizationTests: XCTestCase {
    func testTheCsvFailureSpeaksSixteenLanguages() throws {
        let app = Bundle(for: WebViewController.self)
        let languages = app.localizations.filter { $0 != "Base" }
        XCTAssertEqual(languages.count, 16, languages.sorted().joined(separator: " "))
        for language in languages {
            let path = try XCTUnwrap(app.path(forResource: language, ofType: "lproj"), language)
            let bundle = try XCTUnwrap(Bundle(path: path))
            let text = bundle.localizedString(forKey: "export_csv_failed", value: nil, table: nil)
            XCTAssertNotEqual(text, "export_csv_failed", language)
        }
    }
}
