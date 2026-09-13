import XCTest
@testable import Diptych

/// Listing what is inside a folder or an archive.
///
/// The archives are built here with the system's own tools rather than checked
/// in, so what is being read is a real zip and a real compressed tar rather
/// than a description of one.
final class ListingTests: XCTestCase {

    private var root: URL!
    private let manager = FileManager.default

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("DiptychListing-\(UUID().uuidString)")
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? manager.removeItem(at: root)
    }

    @discardableResult
    private func shell(_ command: String) -> Int32 {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "cd '\(root.path)' && \(command)"]
        task.standardOutput = Pipe()
        task.standardError = Pipe()
        try? task.run()
        task.waitUntilExit()
        return task.terminationStatus
    }

    private func makeTree() throws {
        try manager.createDirectory(at: root.appendingPathComponent("src/sub"),
                                    withIntermediateDirectories: true)
        try Data("hello\n".utf8).write(to: root.appendingPathComponent("src/a.txt"))
        try Data("world\n".utf8).write(to: root.appendingPathComponent("src/sub/b.txt"))
    }

    // MARK: - Folders

    func testAFolderListsWhatIsInIt() throws {
        try makeTree()
        try Data("x".utf8).write(to: root.appendingPathComponent("loose.txt"))

        let result = Listing.folder(at: root)

        XCTAssertNil(result.trouble)
        XCTAssertEqual(result.entries.map(\.name), ["src", "loose.txt"],
                       "folders first, as the panes do")
        XCTAssertTrue(result.entries[0].isDirectory)
        XCTAssertEqual(result.entries[1].size, 1)
    }

    func testAnEmptyFolderIsEmptyRatherThanBroken() throws {
        let result = Listing.folder(at: root)

        XCTAssertNil(result.trouble)
        XCTAssertTrue(result.entries.isEmpty)
    }

    func testAFolderThatCannotBeReadSaysSo() throws {
        let closed = root.appendingPathComponent("closed", isDirectory: true)
        try manager.createDirectory(at: closed, withIntermediateDirectories: true)
        try manager.setAttributes([.posixPermissions: 0o000], ofItemAtPath: closed.path)
        defer { try? manager.setAttributes([.posixPermissions: 0o755],
                                           ofItemAtPath: closed.path) }

        let result = Listing.folder(at: closed)

        XCTAssertNotNil(result.trouble)
    }

    func testAHugeFolderIsCutOffRatherThanBuiltInFull() throws {
        // A preview that has to render a hundred thousand rows is not a
        // preview.
        for index in 0..<(Listing.mostEntries + 25) {
            try Data("x".utf8).write(to: root.appendingPathComponent("file\(index).txt"))
        }

        let result = Listing.folder(at: root)

        XCTAssertEqual(result.entries.count, Listing.mostEntries)
        XCTAssertEqual(result.omitted, 25)
    }

    // MARK: - Archives

    private func listing(of name: String) -> Listing.Result {
        Listing.archive(at: root.appendingPathComponent(name))
    }

    func testAZipListsItsContents() throws {
        try makeTree()
        try XCTSkipIf(shell("zip -qr t.zip src") != 0, "no zip on this machine")

        let result = listing(of: "t.zip")

        XCTAssertNil(result.trouble)
        XCTAssertTrue(result.entries.contains { $0.name == "src/a.txt" },
                      "\(result.entries.map(\.name))")
        XCTAssertEqual(result.entries.first { $0.name == "src/a.txt" }?.size, 6)
    }

    func testEveryCompressedTarTheSystemCanRead() throws {
        try makeTree()
        // One switch reads all of these, which is the whole reason for using
        // the system's tar rather than four decompressors.
        let kinds = [("t.tar", "tar -cf t.tar src"),
                     ("t.tar.gz", "tar -czf t.tar.gz src"),
                     ("t.tar.bz2", "tar -cjf t.tar.bz2 src"),
                     ("t.tar.xz", "tar -cJf t.tar.xz src"),
                     ("t.tar.Z", "tar -cf - src | compress > t.tar.Z")]

        for (name, command) in kinds {
            guard shell(command) == 0 else { continue }
            let result = listing(of: name)

            XCTAssertNil(result.trouble, name)
            XCTAssertTrue(result.entries.contains { $0.name == "src/sub/b.txt" },
                          "\(name): \(result.entries.map(\.name))")
        }
    }

    func testSomethingThatIsNotAnArchiveSaysSo() throws {
        try Data("this is just text\n".utf8).write(to: root.appendingPathComponent("t.zip"))

        let result = listing(of: "t.zip")

        XCTAssertNotNil(result.trouble)
        XCTAssertTrue(result.entries.isEmpty)
    }

    func testAMissingArchiveSaysSoRatherThanWaiting() throws {
        let result = listing(of: "not-there.zip")

        XCTAssertNotNil(result.trouble)
    }

    func testWhichExtensionsAreOffered() {
        XCTAssertTrue(Listing.isArchive(URL(fileURLWithPath: "/a/b.zip")))
        XCTAssertTrue(Listing.isArchive(URL(fileURLWithPath: "/a/b.TGZ")), "whatever the case")
        XCTAssertTrue(Listing.isArchive(URL(fileURLWithPath: "/a/b.tar.gz")),
                      "the last suffix is the one that counts")
        XCTAssertFalse(Listing.isArchive(URL(fileURLWithPath: "/a/b.txt")))
    }

    // MARK: - Reading one line of tar

    func testAPlainLineIsParsed() throws {
        let entry = try XCTUnwrap(Listing.parse(
            "-rw-r--r--  0 verhasp wheel       6 Sep 13 11:38 src/a.txt"))

        XCTAssertEqual(entry.name, "src/a.txt")
        XCTAssertEqual(entry.size, 6)
        XCTAssertFalse(entry.isDirectory)
    }

    func testADirectoryLineIsParsed() throws {
        let entry = try XCTUnwrap(Listing.parse(
            "drwxr-xr-x  0 verhasp wheel       0 Sep 13 11:38 src/sub/"))

        XCTAssertEqual(entry.name, "src/sub/")
        XCTAssertTrue(entry.isDirectory)
        XCTAssertNil(entry.size, "a folder's size in an archive means nothing")
    }

    func testANameWithSpacesSurvives() throws {
        // The name is everything after the date, not the last field.
        let entry = try XCTUnwrap(Listing.parse(
            "-rw-r--r--  0 verhasp wheel      12 Sep 13 11:38 my notes (draft).txt"))

        XCTAssertEqual(entry.name, "my notes (draft).txt")
    }

    func testALinkShowsTheNameNotTheTarget() throws {
        let entry = try XCTUnwrap(Listing.parse(
            "lrwxr-xr-x  0 verhasp wheel       0 Sep 13 11:38 link -> somewhere/else"))

        XCTAssertEqual(entry.name, "link")
    }

    func testRubbishIsIgnoredRatherThanGuessedAt() {
        XCTAssertNil(Listing.parse(""))
        XCTAssertNil(Listing.parse("not a tar line"))
    }
}

/// The page itself.
final class ListingReportTests: XCTestCase {

    private func entry(_ name: String, folder: Bool = false, size: Int64? = 10) -> Listing.Entry {
        Listing.Entry(name: name, isDirectory: folder, size: size, modified: nil)
    }

    func testTheNamesAppear() {
        let result = Listing.Result(entries: [entry("a.txt"), entry("sub", folder: true)])

        let html = ListingReport.html(for: result, name: "things", path: "/a/things",
                                      kind: .folder)

        XCTAssertTrue(html.contains("a.txt"))
        XCTAssertTrue(html.contains("sub"))
        XCTAssertTrue(html.contains("1 file, 1 folder"), "and what is there, counted")
    }

    func testAnEmptyFolderSaysSo() {
        let html = ListingReport.html(for: Listing.Result(), name: "empty", path: "/a/empty",
                                      kind: .folder)

        XCTAssertTrue(html.contains("It is empty."))
    }

    func testTroubleIsShownRatherThanAnEmptyPage() {
        let result = Listing.Result(trouble: "This folder could not be read.")

        let html = ListingReport.html(for: result, name: "x", path: "/x", kind: .folder)

        XCTAssertTrue(html.contains("could not be read"))
        XCTAssertFalse(html.contains("It is empty."), "which would be a different claim")
    }

    func testWhatWasLeftOutIsSaid() {
        let result = Listing.Result(entries: [entry("a")], omitted: 500)

        let html = ListingReport.html(for: result, name: "big", path: "/big", kind: .folder)

        XCTAssertTrue(html.contains("500 more"))
    }

    func testAngleBracketsInANameCannotBreakThePage() {
        let result = Listing.Result(entries: [entry("<script>alert(1)</script>.txt")])

        let html = ListingReport.html(for: result, name: "x", path: "/x", kind: .folder)

        XCTAssertFalse(html.contains("<script>alert"))
        XCTAssertTrue(html.contains("&lt;script&gt;"))
    }
}
