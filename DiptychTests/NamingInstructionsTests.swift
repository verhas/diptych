import XCTest
@testable import Diptych

/// Which instructions a suggested name follows, read from names.tmpl and the
/// files for particular folders. Everything is read from a temporary folder
/// standing in for ~/.diptych/prompts, so no test touches the real one.
final class NamingInstructionsTests: XCTestCase {

    private var prompts: URL!
    private var places: URL!
    private let manager = FileManager.default

    override func setUpWithError() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("DiptychInstructions-\(UUID().uuidString)")
        prompts = root.appendingPathComponent("prompts")
        places = root.appendingPathComponent("places")
        try manager.createDirectory(at: prompts, withIntermediateDirectories: true)
        try manager.createDirectory(at: places, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? manager.removeItem(at: prompts.deletingLastPathComponent())
    }

    // MARK: - The general file

    func testTheGeneralFileIsWrittenWhenMissing() throws {
        let catalogue = NamingInstructions.read(from: prompts)

        let written = prompts.appendingPathComponent("names.tmpl")
        XCTAssertEqual(try String(contentsOf: written, encoding: .utf8),
                       NamingInstructions.generalFile)
        var isFolder: ObjCBool = false
        XCTAssertTrue(manager.fileExists(atPath: prompts.appendingPathComponent("names").path,
                                         isDirectory: &isFolder) && isFolder.boolValue,
                      "the folder for folder files is there to be found")
        XCTAssertEqual(catalogue.general.file, "names.tmpl")
        XCTAssertTrue(catalogue.problems.isEmpty, "\(catalogue.problems)")
    }

    func testTheNotesAreNotSent() {
        // As first written, what is sent is exactly the built-in text: every
        // line of explanation above it is a note.
        let catalogue = NamingInstructions.read(from: prompts)
        XCTAssertEqual(catalogue.general.text, NamingInstructions.builtIn)
    }

    func testAnEditToTheGeneralFileIsWhatIsSent() throws {
        try write("names.tmpl", "# my notes\n\nName every file in French.\n")

        let used = NamingInstructions.read(from: prompts).instructions(for: places)

        XCTAssertEqual(used.text, "Name every file in French.")
        XCTAssertEqual(used.file, "names.tmpl")
        XCTAssertNil(used.folder)
    }

    func testAHashFurtherDownIsPartOfTheInstructions() throws {
        try write("names.tmpl", "# note\nFirst line.\n# Heading\nMore.")

        XCTAssertEqual(NamingInstructions.read(from: prompts).general.text,
                       "First line.\n# Heading\nMore.")
    }

    func testAGeneralFileWithOnlyNotesFallsBackAndSaysSo() throws {
        try write("names.tmpl", "# nothing but notes\n")

        let catalogue = NamingInstructions.read(from: prompts)

        XCTAssertEqual(catalogue.general.text, NamingInstructions.builtIn)
        XCTAssertNil(catalogue.general.file)
        XCTAssertEqual(catalogue.problems.map(\.file), ["names.tmpl"])
    }

    func testUnderInTheGeneralFileIsReported() throws {
        try write("names.tmpl", "# under: ~/Documents\nText.")

        let catalogue = NamingInstructions.read(from: prompts)

        XCTAssertEqual(catalogue.general.text, "Text.")
        XCTAssertEqual(catalogue.problems.count, 1)
    }

    // MARK: - Files for folders

    func testAFolderFileAppliesInItsFolderAndBelow() throws {
        let scans = try folder("Scans")
        let deeper = try folder("Scans/2024/March")
        try write("names/scans.tmpl", "# under: \(scans.path)\nName scans.")

        let catalogue = NamingInstructions.read(from: prompts)

        XCTAssertEqual(catalogue.instructions(for: scans).text, "Name scans.")
        XCTAssertEqual(catalogue.instructions(for: deeper).text, "Name scans.")
        XCTAssertEqual(catalogue.instructions(for: deeper).file, "names/scans.tmpl")
        XCTAssertEqual(catalogue.instructions(for: places).file, "names.tmpl")
    }

    func testAFolderThatOnlyStartsTheSameIsNotInside() throws {
        let scans = try folder("Scans")
        let other = try folder("Scans2")
        try write("names/scans.tmpl", "# under: \(scans.path)\nName scans.")

        XCTAssertEqual(NamingInstructions.read(from: prompts).instructions(for: other).file,
                       "names.tmpl")
    }

    func testTheNearestFolderWinsWhole() throws {
        let scans = try folder("Scans")
        let invoices = try folder("Scans/Invoices")
        try write("names/a-scans.tmpl", "# under: \(scans.path)\nName scans.")
        try write("names/b-invoices.tmpl", "# under: \(invoices.path)\nName invoices.")

        let catalogue = NamingInstructions.read(from: prompts)
        let used = catalogue.instructions(for: invoices.appendingPathComponent("2024"))

        // Not "Name scans. Name invoices." -- one file, as written.
        XCTAssertEqual(used.text, "Name invoices.")
        XCTAssertEqual(used.folder, FileOperations.canonicalPath(invoices))
        XCTAssertEqual(catalogue.instructions(for: scans).text, "Name scans.")
    }

    func testOneFileCanBeForSeveralFolders() throws {
        let one = try folder("Movies")
        let two = try folder("Archive/Movies")
        try write("names/movies.tmpl", "# under: \(one.path), \(two.path)\nName films.")

        let catalogue = NamingInstructions.read(from: prompts)

        XCTAssertEqual(catalogue.instructions(for: one).text, "Name films.")
        XCTAssertEqual(catalogue.instructions(for: two).text, "Name films.")
    }

    func testATildeMeansHome() throws {
        try write("names/home.tmpl", "# under: ~\nAt home.")

        let home = FileManager.default.homeDirectoryForCurrentUser
        XCTAssertEqual(NamingInstructions.read(from: prompts)
                        .instructions(for: home.appendingPathComponent("Documents")).text,
                       "At home.")
    }

    func testAFolderReachedThroughASymlinkIsTheSameFolder() throws {
        // /tmp is a symlink to /private/tmp on macOS; the pane may show either.
        let scans = try folder("Scans")
        let link = places.appendingPathComponent("ScansLink")
        try manager.createSymbolicLink(at: link, withDestinationURL: scans)
        try write("names/scans.tmpl", "# under: \(scans.path)\nName scans.")

        XCTAssertEqual(NamingInstructions.read(from: prompts).instructions(for: link).text,
                       "Name scans.")
    }

    func testOnlyTmplFilesAreRead() throws {
        let scans = try folder("Scans")
        try write("names/scans.txt", "# under: \(scans.path)\nNot this.")

        let catalogue = NamingInstructions.read(from: prompts)

        XCTAssertTrue(catalogue.rules.isEmpty)
        XCTAssertTrue(catalogue.problems.isEmpty, "a file that is not a .tmpl is not ours to judge")
    }

    // MARK: - Mistakes in the files

    func testAFolderFileWithoutUnderIsReportedAndUnused() throws {
        try write("names/scans.tmpl", "# undr: ~/Scans\nName scans.")

        let catalogue = NamingInstructions.read(from: prompts)

        XCTAssertTrue(catalogue.rules.isEmpty)
        let messages = catalogue.problems.filter { $0.file == "names/scans.tmpl" }.map(\.message)
        XCTAssertEqual(messages.count, 2, "the misspelling and the missing line: \(messages)")
    }

    func testASentenceWithAColonInTheNotesIsNotASetting() throws {
        try write("names.tmpl", "# For example: this is a note.\nText.")

        XCTAssertTrue(NamingInstructions.read(from: prompts).problems.isEmpty)
    }

    func testAFolderFileWithNoTextIsReportedAndUnused() throws {
        let scans = try folder("Scans")
        try write("names/scans.tmpl", "# under: \(scans.path)\n\n")

        let catalogue = NamingInstructions.read(from: prompts)

        XCTAssertTrue(catalogue.rules.isEmpty)
        XCTAssertEqual(catalogue.problems.map(\.file), ["names/scans.tmpl"])
    }

    func testTwoFilesForTheSameFolderUseTheFirstAndSaySo() throws {
        let scans = try folder("Scans")
        try write("names/a.tmpl", "# under: \(scans.path)\nFirst.")
        try write("names/b.tmpl", "# under: \(scans.path)\nSecond.")

        let catalogue = NamingInstructions.read(from: prompts)

        XCTAssertEqual(catalogue.instructions(for: scans).text, "First.")
        XCTAssertEqual(catalogue.problems.map(\.file), ["names/b.tmpl"])
    }

    // MARK: - The model follows them

    func testTheModelIsGivenTheInstructions() async throws {
        // Proof that the text reaches the model, not only that it is read: an
        // instruction the default would never produce, and its visible effect.
        let status = NameSuggester.status
        try XCTSkipUnless(status == .ready, status.explanation)

        var style = NameSuggester.Style()
        style.instructions = """
            You suggest names for files from the content between BEGIN CONTENT and \
            END CONTENT. Every name you give starts with the word Scan, followed by \
            two or three words saying what the document is.
            """
        let outcome = await NameSuggester.suggest(
            forText: "Invoice 2024-117 from Garden Services Ltd for hedge trimming, 240 EUR.",
            style: style)

        let name = try XCTUnwrap(outcome.name, "\(outcome)")
        XCTAssertTrue(name.lowercased().hasPrefix("scan"), name)
    }

    // MARK: - Helpers

    private func write(_ path: String, _ contents: String) throws {
        let url = prompts.appendingPathComponent(path)
        try manager.createDirectory(at: url.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    private func folder(_ path: String) throws -> URL {
        let url = places.appendingPathComponent(path)
        try manager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
