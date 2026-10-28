@testable import Calcpace
import XCTest

final class SharePayloadTests: XCTestCase {
    private let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x01])

    private func json(filename: String = "calcpace-run-12.png", data: String? = nil) -> String {
        let fields = ["filename": filename, "data": data ?? png.base64EncodedString()]
        return String(data: try! JSONSerialization.data(withJSONObject: fields), encoding: .utf8)!
    }

    func testAPngWithAPlainName() {
        XCTAssertEqual(SharePayload.parse(json()), SharePayload.Image(filename: "calcpace-run-12.png", bytes: png))
    }

    func testRefusesANameThatIsNotAPlainPng() {
        for name in ["../calcpace.png", ".hidden.png", "run.jpg", "run 12.png", "", "a/b.png", String(repeating: "a", count: 77) + ".png"] {
            XCTAssertNil(SharePayload.parse(json(filename: name)), name)
        }
        XCTAssertNotNil(SharePayload.parse(json(filename: String(repeating: "a", count: 76) + ".png")))
    }

    func testRefusesWhatIsNotAPng() {
        XCTAssertNil(SharePayload.parse(json(data: Data("GIF89a-not-a-png".utf8).base64EncodedString())))
        XCTAssertNil(SharePayload.parse(json(data: "not base64!")))
        XCTAssertNil(SharePayload.parse(json(data: "data:image/png;base64," + png.base64EncodedString())))
        XCTAssertNil(SharePayload.parse("{}"))
        XCTAssertNil(SharePayload.parse("not json"))
        XCTAssertNil(SharePayload.parse(#"{"filename": "a.png", "data": 12}"#))
    }

    func testRefusesTooBigBeforeDecoding() {
        let big = png + Data(count: 20)
        XCTAssertNil(SharePayload.decodePNG(big.base64EncodedString(), maxBytes: 16))
        XCTAssertNotNil(SharePayload.decodePNG(big.base64EncodedString(), maxBytes: big.count))
    }
}

final class SharePagesTests: XCTestCase {
    private let root = URL(string: "https://calcpace.app")!

    func testARunPageInAnyLanguage() {
        for location in ["https://calcpace.app/activities/12", "https://calcpace.app/pt-BR/activities/12/",
                         "https://calcpace.app/zh-TW/activities/12?share=1", "https://calcpace.app/activities/12#share"] {
            XCTAssertTrue(SharePages.isRunPage(URL(string: location), rootURL: root), location)
        }
    }

    func testAnythingElse() {
        for location in ["https://calcpace.app/activities", "https://calcpace.app/activities/12/edit",
                         "https://calcpace.app/activities/new", "https://calcpace.app//activities/12",
                         "https://calcpace.app/xx/activities/12", "https://calcpace.app.evil.example/activities/12",
                         "https://evil.example/activities/12", "https://calcpace.app/activities/%31%32"] {
            XCTAssertFalse(SharePages.isRunPage(URL(string: location), rootURL: root), location)
        }
        XCTAssertFalse(SharePages.isRunPage(nil, rootURL: root))
    }
}

final class ShareFilesTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testKeepsTheNameAndOnlyTheLastFile() throws {
        let first = try ShareFiles.write(Data("one".utf8), named: "run.png", in: ShareFiles.images, root: root)
        let second = try ShareFiles.write(Data("two".utf8), named: "run.png", in: ShareFiles.images, root: root)

        XCTAssertEqual(second.lastPathComponent, "run.png")
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(try Data(contentsOf: second), Data("two".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
        let folders = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(ShareFiles.images).path)
        XCTAssertEqual(folders.count, 1)
    }
}
