import XCTest
@testable import Diptych

/// New from Clipboard ▸ "Ask each time": the format offered first is the one
/// most pictures in the folder are already in.
final class ClipboardImageFormatTests: XCTestCase {

    private typealias Format = Configuration.ClipboardImageFormat

    func testNoPicturesIsPNG() {
        XCTAssertEqual(Format.mostCommon(among: []), .png)
        XCTAssertEqual(Format.mostCommon(among: ["notes.txt", "Makefile", "a.gif"]), .png)
    }

    func testMostFrequentWins() {
        XCTAssertEqual(Format.mostCommon(among: ["a.jpg", "b.JPEG", "c.png"]), .jpeg)
        XCTAssertEqual(Format.mostCommon(among: ["a.pdf", "b.pdf", "c.png", "d.jpg"]), .pdf)
        XCTAssertEqual(Format.mostCommon(among: ["a.png", "b.png", "c.jpg"]), .png)
    }

    func testTiePrefersPNGThenJPEG() {
        XCTAssertEqual(Format.mostCommon(among: ["a.png", "b.jpg", "c.pdf"]), .png)
        XCTAssertEqual(Format.mostCommon(among: ["a.jpg", "b.pdf"]), .jpeg)
    }

    func testReadsTheFolderSkippingHiddenFiles() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for name in ["one.jpg", "two.jpg", "three.png", ".a.png", ".b.png"] {
            try Data().write(to: folder.appendingPathComponent(name))
        }
        XCTAssertEqual(Format.mostCommon(in: folder), .jpeg)
    }
}
