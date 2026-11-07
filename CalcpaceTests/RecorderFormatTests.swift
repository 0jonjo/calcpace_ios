@testable import Calcpace
import XCTest

// The Android app's cases for the GPX and the screen's numbers (RunLogTest.kt,
// the Gpx and RunFormat part), on the same rules: the file the site gets and
// the numbers the runner reads are the same on both phones.
final class RecorderFormatTests: XCTestCase {
    private let t0: Int64 = 1_760_000_000_000 // 2025-10-09T08:53:20Z
    private let id = "3f2504e0-4f89-41d3-9a0c-0305e82c3301"

    private func fix(_ time: Int64, _ lat: Double, _ lon: Double, _ altitude: Double?) -> RunEvent {
        .fix(RunFix(time: time, lat: lat, lon: lon, altitude: altitude, accuracy: 5))
    }

    private func start(_ time: Int64) -> RunEvent {
        .start(time: time, recordingId: nil, utcOffsetSeconds: nil)
    }

    private func count(_ needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    // MARK: Gpx

    func testTheGpxHoldsOneSegmentPerStretchWithTimesInUtc() {
        let track = Track([
            .start(time: t0, recordingId: id, utcOffsetSeconds: -10_800),
            fix(t0, 1.0, 2.0, 10.0),
            fix(t0 + 1000, 1.00003, 2.0, nil),
            .pause(time: t0 + 2000),
            .resume(time: t0 + 3000),
            fix(t0 + 4000, 1.0001, 2.0, nil),
            .stop(time: t0 + 5000),
        ])
        let gpx = Gpx.write(track, name: "Run <1> & co")

        XCTAssertEqual(count("<trkseg>", in: gpx), 2)
        XCTAssertEqual(count("<trkpt ", in: gpx), 3)
        XCTAssertTrue(gpx.contains(#"<trkpt lat="1.0000000" lon="2.0000000"><ele>10.0</ele><time>2025-10-09T08:53:20.000Z</time></trkpt>"#), gpx)
        XCTAssertTrue(gpx.contains("<name>Run &lt;1&gt; &amp; co</name>"))
        XCTAssertTrue(gpx.contains("<type>running</type>"))
        XCTAssertTrue(gpx.contains(
            #"<metadata><time>2025-10-09T08:53:20.000Z</time><extensions><calcpace:recording id="\#(id)" utc_offset="-10800"/></extensions></metadata>"#
        ), gpx)
        XCTAssertTrue(gpx.contains(#"xmlns:calcpace="\#(Gpx.namespace)""#))
    }

    // As the log: a phone in German would write 1,5 for 1.5 if the number
    // followed the language. Android sets the default locale to Germany for
    // this; String(format:) without a locale is never localized.
    func testTheGpxIsWrittenWithDotsWhateverTheLocale() {
        let track = Track([start(t0), fix(t0, -5.84, -35.2, 10.5)])
        XCTAssertTrue(Gpx.write(track, name: "Run").contains(#"<trkpt lat="-5.8400000" lon="-35.2000000"><ele>10.5</ele>"#))
    }

    // An Android log's run from before ids has none: no extension, rather than half of one.
    func testARunWithoutAnIdHasNoRecordingExtension() {
        let gpx = Gpx.write(Track([start(t0)]), name: "Run")
        XCTAssertTrue(gpx.contains("<metadata><time>2025-10-09T08:53:20.000Z</time></metadata>"), gpx)
        XCTAssertFalse(gpx.contains("calcpace:recording"))
    }

    func testTheFileIsNamedInTheRunnersTime() throws {
        let saoPaulo = try XCTUnwrap(TimeZone(identifier: "America/Sao_Paulo"))
        XCTAssertEqual(Gpx.filename(t0, timeZone: saoPaulo), "calcpace-2025-10-09-055320.gpx")
    }

    // MARK: RunFormat

    func testTheScreenReadsLikeARunningApp() {
        XCTAssertEqual(RunFormat.clock(42_400), "0:42")
        XCTAssertEqual(RunFormat.clock(725_000), "12:05")
        XCTAssertEqual(RunFormat.clock(3_729_000), "1:02:09")
        XCTAssertEqual(RunFormat.distance(3_417), "3.42 km")
        XCTAssertEqual(RunFormat.pace(307.4), "5:07 /km")
        XCTAssertEqual(RunFormat.pace(299.6), "5:00 /km")
        XCTAssertEqual(RunFormat.pace(nil), "–:– /km")
        XCTAssertEqual(RunFormat.pace(.infinity), "–:– /km")
    }

    func testDistanceAndPaceFollowTheUnitAndTheLanguage() {
        XCTAssertEqual(RunFormat.distance(5_210, unit: .km, locale: Locale(identifier: "pt_BR")), "5,21 km")
        XCTAssertEqual(RunFormat.distance(5_210, unit: .km, locale: Locale(identifier: "en_US")), "5.21 km")
        XCTAssertEqual(RunFormat.distance(5_210, unit: .mi, locale: Locale(identifier: "en_US")), "3.24 mi")
        XCTAssertEqual(RunFormat.distance(1_234_567, unit: .km, locale: Locale(identifier: "de_DE")), "1234,57 km")
        // Rounded as the site rounds: 2.905 km shows as the site's 2.91.
        XCTAssertEqual(RunFormat.distance(2_905), "2.91 km")
        XCTAssertEqual(RunFormat.distance(-3), "0.00 km")
        // 5:00 /km is 8:03 /mi.
        XCTAssertEqual(RunFormat.pace(300, unit: .mi), "8:03 /mi")
        XCTAssertEqual(RunFormat.pace(nil, unit: .mi), "–:– /mi")
        // 40:00 /km is past an hour a mile: no pace.
        XCTAssertEqual(RunFormat.pace(2_400, unit: .mi), "–:– /mi")
    }

    func testMilesWhereRunnersCountInThem() {
        XCTAssertEqual(RunFormat.Unit.defaultFor(region: "US"), .mi)
        XCTAssertEqual(RunFormat.Unit.defaultFor(region: "GB"), .km)
        XCTAssertEqual(RunFormat.Unit.defaultFor(region: "BR"), .km)
        XCTAssertEqual(RunFormat.Unit.defaultFor(region: nil), .km)

        // The site's language first: only English leaves it to the phone.
        XCTAssertEqual(RunFormat.Unit.defaultFor(siteLocale: "pt-BR", region: "US"), .km)
        XCTAssertEqual(RunFormat.Unit.defaultFor(siteLocale: "de", region: "US"), .km)
        XCTAssertEqual(RunFormat.Unit.defaultFor(siteLocale: "en", region: "US"), .mi)
        XCTAssertEqual(RunFormat.Unit.defaultFor(siteLocale: "en", region: "GB"), .km)
        XCTAssertEqual(RunFormat.Unit.defaultFor(siteLocale: nil, region: "US"), .mi)
    }

    // The site's spelling of the unit (`/record?unit=km`), nothing else.
    func testTheUnitInTheSitesSpelling() {
        XCTAssertEqual(RunFormat.Unit.site("km"), .km)
        XCTAssertEqual(RunFormat.Unit.site("mi"), .mi)
        XCTAssertNil(RunFormat.Unit.site("KM"))
        XCTAssertNil(RunFormat.Unit.site(nil))
    }
}
