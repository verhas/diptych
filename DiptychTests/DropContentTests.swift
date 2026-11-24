import AppKit
import XCTest
import UniformTypeIdentifiers
@testable import Diptych

/// A drop that carries no file -- a picture, a text -- is read the way New
/// from Clipboard reads the clipboard, from the drag's pasteboard.
@MainActor
final class DropContentTests: XCTestCase {

    private var board: NSPasteboard!

    override func setUp() {
        board = NSPasteboard(name: NSPasteboard.Name("DropContentTests-\(UUID().uuidString)"))
        board.clearContents()
    }

    override func tearDown() {
        board.releaseGlobally()
    }

    func testNothingIsNothing() {
        XCTAssertFalse(Clipboard.holdsContent(board))
        XCTAssertEqual(Clipboard.contents(of: board).kind, .empty)
    }

    func testAPictureIsAPicture() throws {
        let image = NSImage(size: NSSize(width: 4, height: 3), flipped: false) { rect in
            NSColor.red.setFill()
            rect.fill()
            return true
        }
        let png = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(image.tiffRepresentation))?
            .representation(using: .png, properties: [:]))
        board.setData(png, forType: .png)
        XCTAssertTrue(Clipboard.holdsContent(board))
        guard case .image(let read, _) = Clipboard.contents(of: board) else {
            return XCTFail("not read as a picture")
        }
        XCTAssertEqual(read.size.width, 4)
    }

    func testAPictureWinsOverItsName() throws {
        let tiff = try XCTUnwrap(NSImage(size: NSSize(width: 2, height: 2), flipped: false) { _ in true }
            .tiffRepresentation)
        board.declareTypes([.tiff, .string], owner: nil)
        board.setData(tiff, forType: .tiff)
        board.setString("picture.png", forType: .string)
        XCTAssertEqual(Clipboard.contents(of: board).kind, .image)
    }

    func testATextIsAText() {
        board.setString("Hello", forType: .string)
        XCTAssertTrue(Clipboard.holdsContent(board))
        guard case .text(let text) = Clipboard.contents(of: board) else {
            return XCTFail("not read as text")
        }
        XCTAssertEqual(text, "Hello")
    }

    func testTheHistorySaysItWasDropped() {
        let url = URL(fileURLWithPath: "/tmp/x/picture.png")
        XCTAssertEqual(FileHistory.Creation.dropped.name, "Drop")
        XCTAssertTrue(FileHistory.Creation.dropped.told([url], folder: "x", names: "picture.png")
            .contains("dropped"))
    }

    // MARK: - Promised files that are only another app's own data

    func testATypeOnlyItsAppKnowsIsNotAFileToMake() throws {
        for open in ["public.png", "com.adobe.pdf", "public.zip-archive", "public.data", "net.daringfireball.markdown"] {
            XCTAssertFalse(AppModel.isPrivateData(open), open)
        }
        XCTAssertFalse(AppModel.isPrivateData("org.example.not-declared-anywhere"), "may be an app not installed")
        XCTAssertFalse(AppModel.isPrivateData(UTType(filenameExtension: "qqqzz")!.identifier), "dynamic")
        let snippad = "dev.verhas.snippad.history-item"
        try XCTSkipUnless(UTType(snippad)?.isDeclared == true, "Snippad is not installed")
        XCTAssertTrue(AppModel.isPrivateData(snippad))
    }

    func testSuchAPromiseIsPassedOverAndARealOneKept() throws {
        final class Writer: NSObject, NSFilePromiseProviderDelegate {
            func filePromiseProvider(_ provider: NSFilePromiseProvider, fileNameForType type: String) -> String { "x" }
            func filePromiseProvider(_ provider: NSFilePromiseProvider, writePromiseTo url: URL,
                                     completionHandler: @escaping (Error?) -> Void) { completionHandler(nil) }
        }
        let writer = Writer()
        let snippad = "dev.verhas.snippad.history-item"
        try XCTSkipUnless(UTType(snippad)?.isDeclared == true, "Snippad is not installed")
        board.writeObjects([NSFilePromiseProvider(fileType: snippad, delegate: writer)])
        XCTAssertEqual(AppModel.filePromises(on: board).count, 0, "Snippad's own reference is not a file")
        board.clearContents()
        board.writeObjects([NSFilePromiseProvider(fileType: UTType.png.identifier, delegate: writer)])
        XCTAssertEqual(AppModel.filePromises(on: board).count, 1, "a picture is")
    }
    /// What SwiftUI put on the drag for a Snippad entry: a promise, the
    /// address of the file it is to write for it (empty until then), and the
    /// picture or text. The address is not a dragged file, whatever the
    /// promise is of; an item without a promise keeps its file.
    func testTheFileBesideAPromiseIsNotADraggedFile() throws {
        let promisedType = NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-content-type")
        let cached = URL(fileURLWithPath: "/tmp/com.apple.SwiftUI.Drag-test/null")
        for type in [UTType.png.identifier, "dev.verhas.snippad.history-item"] {
            board.clearContents()
            let item = NSPasteboardItem()
            item.setString(type, forType: promisedType)
            item.setString(cached.absoluteString, forType: .fileURL)
            item.setString("Hello", forType: .string)
            board.writeObjects([item])
            XCTAssertEqual(AppModel.promisedItemFiles(on: board), [cached.path], type)
        }
        board.clearContents()
        let file = NSPasteboardItem()
        file.setString(cached.absoluteString, forType: .fileURL)
        board.writeObjects([file])
        XCTAssertTrue(AppModel.promisedItemFiles(on: board).isEmpty, "a dragged file is a file")
    }
}
