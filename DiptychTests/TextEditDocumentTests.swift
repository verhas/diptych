import XCTest
@testable import Diptych

/// Text Edit: what a save must keep, and when it must not save at all.
@MainActor
final class TextEditDocumentTests: XCTestCase {

    private var folder: URL!
    private let manager = FileManager.default

    override func setUp() async throws {
        folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("DiptychTextEdit-\(UUID().uuidString)")
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? manager.removeItem(at: folder)
    }

    /// A document whose editor holds `typed`, as the text view would.
    private func open(_ name: String, _ data: Data) throws -> (TextEditDocument, URL) {
        let url = folder.appendingPathComponent(name)
        try data.write(to: url)
        let document = TextEditDocument(url: url)
        document.load()
        return (document, url)
    }

    private func type(_ text: String, into document: TextEditDocument) {
        document.currentText = { text }
        document.noteEdit()
    }

    func testTheEditorSeesPlainNewlines() throws {
        let (document, _) = try open("a.txt", Data("one\r\ntwo\r\n".utf8))
        XCTAssertEqual(document.saved, "one\ntwo\n")
        XCTAssertNil(document.failure)
    }

    func testSavingKeepsWindowsLineEndings() throws {
        let (document, url) = try open("a.txt", Data("one\r\ntwo\r\n".utf8))
        type("one\ntwo\nthree\n", into: document)

        XCTAssertEqual(document.save(), .saved)
        XCTAssertEqual(try Data(contentsOf: url), Data("one\r\ntwo\r\nthree\r\n".utf8))
    }

    func testSavingKeepsTheEncoding() throws {
        let latin1 = try XCTUnwrap("caf\u{E9}\n".data(using: .isoLatin1))
        XCTAssertNil(String(data: latin1, encoding: .utf8), "not valid UTF-8, so a real test")
        let (document, url) = try open("a.txt", latin1)
        type("caf\u{E9} cr\u{E8}me\n", into: document)

        XCTAssertEqual(document.save(), .saved)
        XCTAssertEqual(try Data(contentsOf: url), "caf\u{E9} cr\u{E8}me\n".data(using: .isoLatin1))
    }

    func testAMissingFinalNewlineStaysMissing() throws {
        let (document, url) = try open("a.txt", Data("no newline".utf8))
        type("no newline, still", into: document)

        XCTAssertEqual(document.save(), .saved)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "no newline, still")
    }

    func testTextThatCannotBeWrittenInTheEncodingIsRefused() throws {
        let latin1 = try XCTUnwrap("caf\u{E9}\n".data(using: .isoLatin1))
        let (document, url) = try open("a.txt", latin1)
        type("caf\u{E9} \u{1F600}\n", into: document)

        guard case .failed = document.save() else { return XCTFail("saved what it could not") }
        XCTAssertEqual(try Data(contentsOf: url), latin1, "the file is untouched")
    }

    func testTypingAndUndoingIsNothingToSave() throws {
        let (document, _) = try open("a.txt", Data("same\n".utf8))
        type("same\n", into: document)

        XCTAssertFalse(document.hasUnsavedChanges, "nothing to ask about on closing")
        XCTAssertEqual(document.save(), .nothingToDo)
        XCTAssertFalse(document.isEdited)
    }

    func testAFileChangedElsewhereIsNotOverwrittenWithoutBeingAsked() throws {
        let (document, url) = try open("a.txt", Data("mine\n".utf8))
        try Data("theirs\n".utf8).write(to: url)
        try manager.setAttributes([.modificationDate: Date().addingTimeInterval(60)],
                                  ofItemAtPath: url.path)
        type("mine, edited\n", into: document)

        XCTAssertEqual(document.save(), .changedUnderneath)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "theirs\n")

        XCTAssertEqual(document.save(overwriting: true), .saved)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "mine, edited\n")
    }

    func testABinaryFileIsNotOpenedAsText() throws {
        let (document, _) = try open("a.bin", Data([0x00, 0x01, 0x02, 0xFF]))
        XCTAssertNotNil(document.failure)
        XCTAssertTrue(document.failure?.contains("Bin Edit") ?? false, document.failure ?? "")
    }

    func testAFileThatCannotBeWrittenOpensReadOnly() throws {
        let (document, url) = try open("a.txt", Data("locked\n".utf8))
        try manager.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)
        document.load()
        defer { try? manager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path) }

        XCTAssertTrue(document.isReadOnly)
        type("changed\n", into: document)
        XCTAssertEqual(document.save(), .nothingToDo)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "locked\n")
    }

    func testSavingKeepsPermissions() throws {
        let (document, url) = try open("run.sh", Data("#!/bin/sh\n".utf8))
        try manager.setAttributes([.posixPermissions: 0o750], ofItemAtPath: url.path)
        document.load()
        type("#!/bin/sh\necho hi\n", into: document)

        XCTAssertEqual(document.save(), .saved)
        let mode = try manager.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o750)
    }

    func testTheSummarySaysWhatSavingKeeps() throws {
        let (document, _) = try open("a.txt", Data("one\r\n".utf8))
        XCTAssertTrue(document.summary.contains("CRLF"), document.summary)
    }
}
