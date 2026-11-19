import XCTest
@testable import Diptych

/// Where a file came from, read from its extended attributes, and the
/// section Quick Look ends a report with.
final class FileOriginTests: XCTestCase {

    private var file: URL!

    override func setUp() async throws {
        file = FileManager.default.temporaryDirectory.appendingPathComponent("FileOrigin-\(UUID().uuidString).zip")
        try Data("x".utf8).write(to: file)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: file)
    }

    private func set(_ name: String, _ data: Data) throws {
        let result = data.withUnsafeBytes { setxattr(file.path, name, $0.baseAddress, data.count, 0, 0) }
        XCTAssertEqual(result, 0, "\(name): \(String(cString: strerror(errno)))")
    }

    private func downloaded(opened: Bool, from addresses: [String]) throws {
        let seconds = String(Int(Date(timeIntervalSince1970: 1_700_000_000).timeIntervalSince1970), radix: 16)
        try set(FileOrigin.quarantineName, Data("\(opened ? "0063" : "0083");\(seconds);Safari;".utf8))
        try set(FileOrigin.whereFromName,
                try PropertyListSerialization.data(fromPropertyList: addresses, format: .binary, options: 0))
    }

    func testAFileMadeHereHasNoSectionUnderItsPreview() throws {
        // At most the provenance tag of whatever wrote it.
        let origin = try XCTUnwrap(FileOrigin.read(file))
        XCTAssertFalse(origin.isDownload)
        XCTAssertEqual(origin.others, [])
        XCTAssertEqual(origin.html(provenanceText: "an app"), "", "nothing to say under a preview")
    }

    func testADownloadSaysWhereFromByWhatAndWhetherItWasOpened() throws {
        try downloaded(opened: false, from: ["https://example.com/a.zip", "https://example.com/"])
        try set("org.example.note", Data(count: 12))
        let origin = try XCTUnwrap(FileOrigin.read(file))
        XCTAssertEqual(origin.whereFrom, ["https://example.com/a.zip", "https://example.com/"])
        XCTAssertEqual(origin.quarantine?.agent, "Safari")
        XCTAssertEqual(origin.quarantine?.opened, false)
        XCTAssertEqual(origin.quarantine?.date, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(origin.others, [.init(name: "org.example.note", size: 12)])
        XCTAssertEqual(origin.warnings.count, 1)
        XCTAssertTrue(origin.warnings[0].hasPrefix("Downloaded and never opened"))

        let html = origin.html(provenanceText: nil)
        XCTAssertTrue(html.contains("<a href=\"https://example.com/a.zip\">"))
        XCTAssertTrue(html.contains("Linked from"))
        XCTAssertTrue(html.contains("Quarantined by Safari"))
        XCTAssertTrue(html.contains("org.example.note"))
    }

    func testOpenedSinceIsNoWarning() throws {
        try downloaded(opened: true, from: ["https://example.com/a.zip"])
        let origin = try XCTUnwrap(FileOrigin.read(file))
        XCTAssertEqual(origin.quarantine?.opened, true)
        XCTAssertEqual(origin.warnings, [])
        XCTAssertTrue(origin.quarantineText?.hasSuffix("opened since") == true)
    }

    func testASiteSpelledInOtherLettersIsPointedOut() throws {
        // "аpple.com" with a Cyrillic а.
        try downloaded(opened: true, from: ["https://xn--pple-43d.com/x.dmg"])
        let warnings = try XCTUnwrap(FileOrigin.read(file)).warnings
        XCTAssertEqual(warnings.count, 1)
        XCTAssertTrue(warnings[0].contains("\u{0430}pple.com"), warnings[0])
    }

    func testTheSectionGoesInOnceBeforeThePageEnds() {
        let section = FileOrigin(whereFrom: ["https://example.com/"]).html(provenanceText: nil)
        let page = FileOrigin.adding(section, to: "<html><body><h1>x</h1></body></html>")
        XCTAssertTrue(page.hasSuffix("</section></body></html>"), page)
        XCTAssertEqual(FileOrigin.adding(section, to: page), page, "not twice")
        XCTAssertEqual(FileOrigin.adding("", to: "<body></body>"), "<body></body>")
    }
}
