import XCTest
import AppKit
import ImageIO
import UniformTypeIdentifiers
@testable import Diptych

/// What a file says about itself, read out of real files written here.
final class FormatDetailsTests: XCTestCase {

    private var folder: URL!
    private let manager = FileManager.default

    override func setUpWithError() throws {
        folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("DiptychDetails-\(UUID().uuidString)")
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? manager.removeItem(at: folder)
    }

    // MARK: - Names

    func testAnAbbreviationStaysWholeAndTheRestReadsAsWords() {
        XCTAssertEqual(FormatDetails.prettify("ISOSpeedRatings"), "ISO speed ratings")
        XCTAssertEqual(FormatDetails.prettify("PixelWidth"), "Pixel width")
        XCTAssertEqual(FormatDetails.prettify("DateTimeOriginal"), "Date time original")
        XCTAssertEqual(FormatDetails.prettify("FNumber"), "F number")
        XCTAssertEqual(FormatDetails.prettify("GPSLatitudeRef"), "GPS latitude ref")
        XCTAssertEqual(FormatDetails.prettify("Title"), "Title")
        XCTAssertEqual(FormatDetails.prettify(""), "")
    }

    // MARK: - Values

    func testValuesAreTurnedIntoSomethingReadable() {
        XCTAssertEqual(FormatDetails.describe(42 as NSNumber), "42")
        XCTAssertEqual(FormatDetails.describe(true as NSNumber), "Yes")
        XCTAssertEqual(FormatDetails.describe(false as NSNumber), "No")
        XCTAssertEqual(FormatDetails.describe(["a", "b"]), "a, b")
        XCTAssertEqual(FormatDetails.describe("  spaced  "), "spaced")
    }

    func testWhatIsNotWorthALineIsLeftOut() {
        XCTAssertNil(FormatDetails.describe(Data([0, 1, 2])), "a maker note is not a fact")
        XCTAssertNil(FormatDetails.describe(""))
        XCTAssertNil(FormatDetails.describe([Data()]))
        let long = String(repeating: "x", count: 1000)
        XCTAssertEqual(FormatDetails.describe(long)?.count, FormatDetails.longestValue)
    }

    // MARK: - Pictures

    /// A PNG with real EXIF and TIFF written into it by ImageIO. Its pixel
    /// size comes back with it: a bitmap drawn on this screen is twice the
    /// size asked for, which is the screen's business and not the reader's.
    @discardableResult
    private func picture(named name: String) throws -> (url: URL, width: Int, height: Int) {
        let url = folder.appendingPathComponent(name)
        let image = NSImage(size: CGSize(width: 120, height: 80))
        image.lockFocus()
        NSColor.systemTeal.setFill()
        CGRect(x: 0, y: 0, width: 120, height: 80).fill()
        image.unlockFocus()
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(tiff as CFData, nil))
        let cgImage = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))

        let data = NSMutableData()
        let type = UTType.png.identifier as CFString
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, type, 1, nil))
        let properties: [CFString: Any] = [
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifLensModel: "Diptych 50mm",
                kCGImagePropertyExifISOSpeedRatings: [200],
                kCGImagePropertyExifDateTimeOriginal: "2026:09:16 11:22:33",
            ] as [CFString: Any],
            kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFMake: "Diptych",
            ] as [CFString: Any],
        ]
        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        try (data as Data).write(to: url)
        return (url, cgImage.width, cgImage.height)
    }

    func testAPictureReportsItsSizeAndItsEXIF() throws {
        let written = try picture(named: "shot.png")

        let sections = FormatDetails.image(written.url)

        let titles = sections.map(\.title)
        XCTAssertTrue(titles.contains("Picture"), "\(titles)")
        XCTAssertTrue(titles.contains("EXIF"), "\(titles)")

        let picture = try XCTUnwrap(sections.first { $0.title == "Picture" })
        XCTAssertEqual(picture.rows.first { $0.name == "Pixel width" }?.value,
                       "\(written.width)")
        XCTAssertEqual(picture.rows.first { $0.name == "Pixel height" }?.value,
                       "\(written.height)")

        let exif = try XCTUnwrap(sections.first { $0.title == "EXIF" })
        XCTAssertEqual(exif.rows.first { $0.name == "Lens model" }?.value, "Diptych 50mm")
        XCTAssertEqual(exif.rows.first { $0.name == "ISO speed ratings" }?.value, "200")
        XCTAssertTrue(exif.rows.first { $0.name == "Date time original" }?.value
                          .contains("2026") ?? false)
        XCTAssertEqual(exif.rows.map(\.name).sorted(), exif.rows.map(\.name),
                       "rows are in a settled order")
    }

    func testSomethingThatIsNotAPictureSaysNothingAboutPictures() throws {
        let url = folder.appendingPathComponent("notes.txt")
        try Data("text".utf8).write(to: url)

        XCTAssertTrue(FormatDetails.image(url).isEmpty)
        XCTAssertTrue(FormatDetails.pdf(url).isEmpty)
    }

    // MARK: - PDF

    private func document(named name: String, title: String) throws -> URL {
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)   // A4 in points
        let url = folder.appendingPathComponent(name)
        let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box,
                                              [kCGPDFContextTitle as String: title,
                                               kCGPDFContextAuthor as String: "Diptych"]
                                              as CFDictionary))
        context.beginPDFPage(nil)
        context.endPDFPage()
        context.closePDF()
        return url
    }

    func testAPDFReportsItsPagesSizeAndTitle() throws {
        let url = try document(named: "report.pdf", title: "Quarterly report")

        let sections = FormatDetails.pdf(url)

        let about = try XCTUnwrap(sections.first { $0.title == "PDF" })
        XCTAssertEqual(about.rows.first { $0.name == "Pages" }?.value, "1")
        XCTAssertEqual(about.rows.first { $0.name == "Encrypted" }?.value, "No")
        let page = try XCTUnwrap(about.rows.first { $0.name == "First page" }?.value)
        XCTAssertTrue(page.contains("595"), page)
        XCTAssertTrue(page.contains("210"), "and A4 in millimetres: \(page)")

        let written = try XCTUnwrap(sections.first { $0.title == "PDF document" })
        XCTAssertEqual(written.rows.first { $0.name == "Title" }?.value, "Quarterly report")
        XCTAssertEqual(written.rows.first { $0.name == "Author" }?.value, "Diptych")
    }

    // MARK: - The whole report

    func testTheReportOfAPictureIsItsPictureSections() async throws {
        let url = try picture(named: "whole.png").url

        let report = await FormatDetails.read(url)

        XCTAssertFalse(report.isEmpty)
        XCTAssertNil(report.nothing)
        XCTAssertTrue(report.sections.contains { $0.title == "EXIF" })
    }

    func testAFileWithNothingToSayIsToldSo() async throws {
        let url = folder.appendingPathComponent("plain.bin")
        try Data([0x01, 0x02, 0x03]).write(to: url)

        let report = await FormatDetails.read(url)

        // Spotlight may know its kind even here; if it does not, the tab says
        // there is nothing rather than showing an empty list.
        if report.isEmpty {
            XCTAssertNotNil(report.nothing)
        } else {
            XCTAssertEqual(report.sections.map(\.title), ["Spotlight"])
        }
    }

    @MainActor
    func testTheInfoWindowModelFillsTheTab() async throws {
        let url = try picture(named: "model.png").url
        let model = FileInfoModel(url: url)

        model.readDetails()
        for _ in 0 ..< 200 where model.details == nil {
            try await Task.sleep(for: .milliseconds(25))
        }

        XCTAssertFalse(model.isReadingDetails)
        XCTAssertTrue(try XCTUnwrap(model.details).sections.contains { $0.title == "EXIF" })
    }
}
