import XCTest
@testable import Diptych

/// Copy ▸ Content is offered only where it can work, and reads what it
/// offered: text as text, one picture as a picture, and nothing binary.
final class CopyContentsTests: XCTestCase {

    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("CopyContentsTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func file(_ name: String, _ data: Data) throws -> (url: URL, bytes: Int64) {
        let url = folder.appendingPathComponent(name)
        try data.write(to: url)
        return (url, Int64(data.count))
    }

    /// The first bytes of a real zip: "PK\3\4", then a version with a NUL in it.
    private let zipStart = Data([0x50, 0x4B, 0x03, 0x04, 0x14, 0x00, 0x00, 0x00])
    private let pngStart = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00])

    func testATextFileIsOffered() throws {
        let notes = try file("notes.txt", Data("hello\n".utf8))
        XCTAssertTrue(Clipboard.canReadContents(of: [notes]))
    }

    func testAnArchiveIsNotOffered() throws {
        let zip = try file("bundle.zip", zipStart)
        XCTAssertFalse(Clipboard.canReadContents(of: [zip]))
    }

    func testTextWithNoExtensionIsOfferedByLookingInside() throws {
        let makefile = try file("Makefile", Data("all:\n\techo hi\n".utf8))
        XCTAssertTrue(Clipboard.canReadContents(of: [makefile]))
    }

    func testBinaryWithNoExtensionIsNotOffered() throws {
        let blob = try file("blob", zipStart)
        XCTAssertFalse(Clipboard.canReadContents(of: [blob]))
    }

    func testOnePictureIsOfferedButTwoAreNot() throws {
        let one = try file("one.png", pngStart)
        let two = try file("two.png", pngStart)
        XCTAssertTrue(Clipboard.canReadContents(of: [one]))
        XCTAssertFalse(Clipboard.canReadContents(of: [one, two]))
    }

    func testOneBinaryFileSpoilsASelection() throws {
        let notes = try file("notes.txt", Data("hello".utf8))
        let zip = try file("bundle.zip", zipStart)
        XCTAssertFalse(Clipboard.canReadContents(of: [notes, zip]))
    }

    func testNothingSelectedIsNotOffered() {
        XCTAssertFalse(Clipboard.canReadContents(of: []))
    }

    func testTooMuchIsNotOffered() throws {
        let notes = try file("notes.txt", Data("hello".utf8))
        let claimed = (notes.url, Int64(Clipboard.contentLimit) + 1)
        XCTAssertFalse(Clipboard.canReadContents(of: [claimed]))
    }

    func testSeveralTextFilesAreReadOneAfterAnother() throws {
        let a = try file("a.txt", Data("first".utf8))
        let b = try file("b.txt", Data("second\n".utf8))
        guard case .text(let text) = Clipboard.readContents(of: [a.url, b.url]) else {
            return XCTFail("expected text")
        }
        XCTAssertEqual(text, "first\nsecond\n")
    }

    func testABinaryFileIsRefusedWhenRead() throws {
        let blob = try file("blob", zipStart)
        guard case .refused = Clipboard.readContents(of: [blob.url]) else {
            return XCTFail("expected a refusal")
        }
    }
}
