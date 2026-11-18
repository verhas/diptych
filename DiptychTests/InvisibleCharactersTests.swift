import XCTest
@testable import Diptych

/// Text Edit's invisible characters: which they are, the byte-order mark kept
/// in the text where it can be deleted, and -- shown -- that they neither act
/// nor hide.
@MainActor
final class InvisibleCharactersTests: XCTestCase {

    private var folder: URL!
    private var window: NSWindow?

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("InvisibleCharactersTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        window?.close()
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: - Which characters

    func testControlAndFormatCharactersAreInvisibleButTabAndNewlineAreNot() {
        for value: UInt32 in [0x00, 0x08, 0x0D, 0x1B, 0x7F, 0x85, 0xAD, 0x200B, 0x200D, 0x202E, 0x2066,
                              0x2028, 0x2029, 0xFEFF, 0xE0041] {
            XCTAssertTrue(InvisibleCharacters.isInvisible(value), String(format: "U+%04X", value))
        }
        for value: UInt32 in [0x09, 0x0A, 0x20, 0x41, 0xE9, 0x05D0, 0x1F600] {
            XCTAssertFalse(InvisibleCharacters.isInvisible(value), String(format: "U+%04X", value))
        }
        XCTAssertTrue(InvisibleCharacters.isDirectionControl(0x202E))
        XCTAssertFalse(InvisibleCharacters.isDirectionControl(0x200B))
    }

    func testLabels() {
        XCTAssertEqual(InvisibleCharacters.label(0xFEFF, atStart: true), "BOM")
        XCTAssertEqual(InvisibleCharacters.label(0xFEFF), "ZWNBSP")
        XCTAssertEqual(InvisibleCharacters.label(0x202E), "RLO")
        XCTAssertEqual(InvisibleCharacters.label(0x1B), "ESC")
        XCTAssertEqual(InvisibleCharacters.label(0x00), "NUL")
        XCTAssertEqual(InvisibleCharacters.label(0xE0041), "U+E0041")
    }

    func testPositionsCountCharactersOutsideTheFirstPlaneOnce() {
        let text = "a\u{200B}b\u{E0041}c" as NSString
        let found = InvisibleCharacters.positions(in: text)
        XCTAssertEqual(found.map(\.location), [1, 3])
        XCTAssertEqual(found.map(\.value), [0x200B, 0xE0041])
        XCTAssertEqual(InvisibleCharacters.summary(of: "x\u{202E}y" as NSString).directional, true)
    }

    // MARK: - The byte-order mark is in the text

    private func open(_ data: Data) throws -> (TextEditDocument, URL) {
        let url = folder.appendingPathComponent("marked.txt")
        try data.write(to: url)
        let document = TextEditDocument(url: url)
        document.load()
        return (document, url)
    }

    func testAByteOrderMarkIsShownAndKept() throws {
        let (document, url) = try open(Data([0xEF, 0xBB, 0xBF] + Array("hi\n".utf8)))
        XCTAssertEqual(document.saved, "\u{FEFF}hi\n")
        document.currentText = { "\u{FEFF}hi there\n" }
        document.noteEdit()
        XCTAssertEqual(document.save(), .saved)
        XCTAssertEqual(try Data(contentsOf: url), Data([0xEF, 0xBB, 0xBF] + Array("hi there\n".utf8)))
    }

    func testDeletingTheByteOrderMarkTakesItOutOfTheFile() throws {
        let (document, url) = try open(Data([0xEF, 0xBB, 0xBF] + Array("hi\n".utf8)))
        document.currentText = { "hi\n" }
        document.noteEdit()
        XCTAssertEqual(document.save(), .saved)
        XCTAssertEqual(try Data(contentsOf: url), Data("hi\n".utf8))
    }

    func testAUTF16FileKeepsItsMarkAndItsByteOrder() throws {
        let body = try XCTUnwrap("hi\n".data(using: .utf16LittleEndian))
        let (document, url) = try open(Data([0xFF, 0xFE]) + body)
        XCTAssertEqual(document.saved, "\u{FEFF}hi\n")
        document.currentText = { "\u{FEFF}ho\n" }
        document.noteEdit()
        XCTAssertEqual(document.save(), .saved)
        XCTAssertEqual(try Data(contentsOf: url), Data([0xFF, 0xFE]) + "ho\n".data(using: .utf16LittleEndian)!)
    }

    // MARK: - Shown, they do not act

    private func editor(_ text: String) -> TextEditController {
        let document = TextEditDocument(url: folder.appendingPathComponent("shown.txt"))
        let controller = TextEditController(document: document)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        controller.view.frame = window.contentLayoutRect
        window.contentView = controller.view
        self.window = window
        controller.loaded(text: text)
        return controller
    }

    private func positions(_ controller: TextEditController) -> [(x: CGFloat, line: CGFloat)] {
        let layout = controller.textView.layoutManager!
        layout.ensureLayout(for: controller.textView.textContainer!)
        return (0..<controller.nsText.length).map { index in
            let glyph = layout.glyphIndexForCharacter(at: index)
            return (layout.location(forGlyphAt: glyph).x,
                    layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY)
        }
    }

    func testAnOverrideReversesTextUntilShown() {
        let controller = editor("ab\u{202E}cd")
        XCTAssertEqual(controller.invisibleCount, 1)
        let hidden = positions(controller)
        XCTAssertGreaterThan(hidden[3].x, hidden[4].x, "c is drawn after d: the override acts")

        controller.showsInvisibles = true
        let shown = positions(controller)
        XCTAssertLessThan(shown[0].x, shown[1].x)
        XCTAssertLessThan(shown[2].x, shown[3].x, "the label takes room before c")
        XCTAssertLessThan(shown[3].x, shown[4].x, "c before d: the override does nothing")
        XCTAssertGreaterThan(shown[3].x - shown[2].x, shown[1].x - shown[0].x, "the label is wider than a letter")
    }

    func testALineSeparatorBreaksNoLineWhenShown() {
        let controller = editor("one\u{2028}two")
        let hidden = positions(controller)
        XCTAssertGreaterThan(hidden[4].line, hidden[0].line)
        controller.showsInvisibles = true
        let shown = positions(controller)
        XCTAssertEqual(shown[4].line, shown[0].line)
        XCTAssertGreaterThan(shown[4].x, shown[2].x)
    }

    func testTypingOneIsCounted() {
        let controller = editor("plain")
        XCTAssertEqual(controller.invisibleCount, 0)
        controller.textView.string = "pl\u{200B}ain"
        controller.textChanged()
        XCTAssertEqual(controller.invisibleCount, 1)
    }
}
