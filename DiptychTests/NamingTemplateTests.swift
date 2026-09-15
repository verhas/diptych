import XCTest
@testable import Diptych

/// Which template a suggested name is asked with, read from names.tmpl and
/// the templates for particular folders, and how it is filled in. Everything is read from a temporary folder
/// standing in for ~/.diptych/prompts, so no test touches the real one.
final class NamingTemplateTests: XCTestCase {

    private var prompts: URL!
    private var places: URL!
    private let manager = FileManager.default

    override func setUpWithError() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("DiptychTemplates-\(UUID().uuidString)")
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
        let catalogue = NamingTemplate.read(from: prompts)

        let written = prompts.appendingPathComponent("names.tmpl")
        XCTAssertEqual(try String(contentsOf: written, encoding: .utf8),
                       NamingTemplate.generalFile)
        var isFolder: ObjCBool = false
        XCTAssertTrue(manager.fileExists(atPath: prompts.appendingPathComponent("names").path,
                                         isDirectory: &isFolder) && isFolder.boolValue,
                      "the folder for folder files is there to be found")
        XCTAssertEqual(catalogue.general.file, "names.tmpl")
        XCTAssertTrue(catalogue.problems.isEmpty, "\(catalogue.problems)")
    }

    func testTheNotesAreNotSent() {
        // As first written, what is sent is exactly the built-in template:
        // every line of explanation above it -- placeholders listed in it
        // included -- is a note.
        let general = NamingTemplate.read(from: prompts).general
        XCTAssertEqual(general.instructions, NamingTemplate.Template.builtIn.instructions)
        XCTAssertEqual(general.prompt, NamingTemplate.Template.builtIn.prompt)
    }

    func testEveryPlaceholderIsListedInTheNotes() {
        for entry in NamingTemplate.placeholders {
            XCTAssertTrue(NamingTemplate.generalFile.contains("{{\(entry.key)}}"), entry.key)
        }
    }

    func testAnEditToTheGeneralFileIsWhatIsSent() throws {
        try write("names.tmpl", "# my notes\n\nName every file in French.\n\n{{content}}\n")

        let used = NamingTemplate.read(from: prompts).template(for: places)

        XCTAssertEqual(used.instructions, "Name every file in French.")
        XCTAssertEqual(used.prompt, "{{content}}")
        XCTAssertEqual(used.file, "names.tmpl")
        XCTAssertNil(used.folder)
    }

    func testAHashFurtherDownIsPartOfTheTemplate() throws {
        try write("names.tmpl", "# note\nFirst line.\n# Heading\nMore.")

        XCTAssertEqual(NamingTemplate.read(from: prompts).general.prompt,
                       "First line.\n# Heading\nMore.")
    }

    func testAGeneralFileWithOnlyNotesFallsBackAndSaysSo() throws {
        try write("names.tmpl", "# nothing but notes\n")

        let catalogue = NamingTemplate.read(from: prompts)

        XCTAssertEqual(catalogue.general, NamingTemplate.Template.builtIn)
        XCTAssertEqual(catalogue.problems.map(\.file), ["names.tmpl"])
    }

    func testUnderInTheGeneralFileIsReported() throws {
        try write("names.tmpl", "# under: ~/Documents\nText {{content}}.")

        let catalogue = NamingTemplate.read(from: prompts)

        XCTAssertEqual(catalogue.general.prompt, "Text {{content}}.")
        XCTAssertEqual(catalogue.problems.count, 1)
    }

    // MARK: - Placeholders

    func testTheSplitIsAtTheParagraphOfTheFirstPlaceholder() {
        let (instructions, prompt) = NamingTemplate.split("""
            Do this.
            And this.

            File: {{name}}
            BEGIN
            {{content}}
            END
            """)

        XCTAssertEqual(instructions, "Do this.\nAnd this.")
        XCTAssertEqual(prompt, "File: {{name}}\nBEGIN\n{{content}}\nEND")
    }

    func testAParagraphIsKeptWholeOnThePromptSide() {
        // The fence line above the placeholder belongs with it: splitting at
        // the line would put "BEGIN CONTENT" in the instructions.
        let (instructions, prompt) = NamingTemplate.split(NamingTemplate.builtInBody)

        XCTAssertFalse(instructions.contains("{{"))
        XCTAssertTrue(prompt.hasPrefix("BEGIN CONTENT"), prompt)
    }

    func testWithoutPlaceholdersTheWholeTextIsThePrompt() {
        let (instructions, prompt) = NamingTemplate.split("Just this.")
        XCTAssertEqual(instructions, "")
        XCTAssertEqual(prompt, "Just this.")
    }

    func testAPlaceholderInTheFirstParagraphLeavesNoInstructions() {
        let (instructions, prompt) = NamingTemplate.split("Name {{name}} well.\nPlease.")
        XCTAssertEqual(instructions, "")
        XCTAssertEqual(prompt, "Name {{name}} well.\nPlease.")
    }

    func testRenderingFillsThePromptOnly() {
        let template = NamingTemplate.Template(
            body: "Rules.\n\nName: {{name}}\nChanged: {{ modified }}\n{{content}}",
            file: nil, folder: nil)

        let prompt = template.render(content: "hello", details: ["name": "a.txt",
                                                                 "modified": "2026-09-15 10:00"])

        XCTAssertEqual(prompt, "Name: a.txt\nChanged: 2026-09-15 10:00\nhello")
        XCTAssertEqual(template.instructions, "Rules.")
    }

    func testContentThatLooksLikeAPlaceholderIsNotFilledIn() {
        let template = NamingTemplate.Template(body: "{{content}} / {{name}}", file: nil, folder: nil)

        let prompt = template.render(content: "{{name}}", details: ["name": "real.txt"])

        XCTAssertEqual(prompt, "{{name}} / real.txt")
    }

    func testAMisspeltPlaceholderIsReported() throws {
        try write("names.tmpl", "{{content}} {{nmae}}")

        let problems = NamingTemplate.read(from: prompts).problems

        XCTAssertEqual(problems.count, 1)
        XCTAssertTrue(problems.first?.message.contains("{{nmae}}") ?? false)
    }

    func testATemplateWithoutTheContentIsReportedButUsed() throws {
        try write("names.tmpl", "Name it after {{stem}}.")

        let catalogue = NamingTemplate.read(from: prompts)

        XCTAssertEqual(catalogue.general.file, "names.tmpl")
        XCTAssertFalse(catalogue.general.usesContent)
        XCTAssertEqual(catalogue.problems.count, 1)
    }

    // MARK: - What is known about a file

    func testTheDetailsOfAFile() throws {
        let url = places.appendingPathComponent("Report 2024.txt")
        try Data("twelve bytes".utf8).write(to: url)
        try manager.setAttributes([.posixPermissions: 0o640,
                                   .modificationDate: Date(timeIntervalSince1970: 1_700_000_000)],
                                  ofItemAtPath: url.path)

        let details = NameSuggester.fileDetails(of: url)

        XCTAssertEqual(details["name"], "Report 2024.txt")
        XCTAssertEqual(details["stem"], "Report 2024")
        XCTAssertEqual(details["extension"], "txt")
        XCTAssertEqual(details["folderName"], "places")
        XCTAssertEqual(details["kind"], "text")
        XCTAssertEqual(details["bytes"], "12")
        XCTAssertEqual(details["permissions"], "rw-r-----")
        XCTAssertEqual(details["owner"], NSUserName())
        XCTAssertEqual(details["modified"],
                       NameSuggester.stamp(Date(timeIntervalSince1970: 1_700_000_000)))
        XCTAssertNotNil(details["created"])
        XCTAssertEqual(details["today"]?.count, 10)
        for entry in NamingTemplate.placeholders where entry.key != "content" {
            XCTAssertNotNil(details[entry.key], "every placeholder but the content: \(entry.key)")
        }
    }

    func testDatesAreWrittenTheSameWayEverywhere() {
        var parts = DateComponents()
        parts.year = 2026; parts.month = 9; parts.day = 5; parts.hour = 7; parts.minute = 3
        let date = Calendar.current.date(from: parts)!
        XCTAssertEqual(NameSuggester.stamp(date), "2026-09-05 07:03")
    }

    func testAHiddenCharacterInANameIsMadeVisible() {
        // A right-to-left override would show the person one name and the
        // model another.
        let details = NameSuggester.details(name: "invoice\u{202E}fdp.exe", folder: places,
                                            bytes: 0, kind: "text")
        XCTAssertFalse(details["name"]?.unicodeScalars.contains("\u{202E}") ?? true)
        XCTAssertTrue(details["name"]?.contains("\\u{202E}") ?? false, details["name"] ?? "")
    }

    func testANewFileFromTheClipboardHasNoPermissionsYet() {
        let details = NameSuggester.details(name: "untitled.png", folder: places,
                                            bytes: 2048, kind: "picture")
        XCTAssertEqual(details["permissions"], "")
        XCTAssertEqual(details["extension"], "png")
        XCTAssertEqual(details["kind"], "picture")
        XCTAssertEqual(details["created"], details["modified"])
    }

    func testTheKindFollowsHowTheContentIsRead() {
        XCTAssertEqual(NameSuggester.kind(of: URL(fileURLWithPath: "/a/b.PDF")), "PDF")
        XCTAssertEqual(NameSuggester.kind(of: URL(fileURLWithPath: "/a/b.heic")), "picture")
        XCTAssertEqual(NameSuggester.kind(of: URL(fileURLWithPath: "/a/b.swift")), "text")
    }

    // MARK: - Files for folders

    func testAFolderFileAppliesInItsFolderAndBelow() throws {
        let scans = try folder("Scans")
        let deeper = try folder("Scans/2024/March")
        try write("names/scans.tmpl", "# under: \(scans.path)\nName scans.")

        let catalogue = NamingTemplate.read(from: prompts)

        XCTAssertEqual(catalogue.template(for: scans).prompt, "Name scans.")
        XCTAssertEqual(catalogue.template(for: deeper).prompt, "Name scans.")
        XCTAssertEqual(catalogue.template(for: deeper).file, "names/scans.tmpl")
        XCTAssertEqual(catalogue.template(for: places).file, "names.tmpl")
    }

    func testAFolderThatOnlyStartsTheSameIsNotInside() throws {
        let scans = try folder("Scans")
        let other = try folder("Scans2")
        try write("names/scans.tmpl", "# under: \(scans.path)\nName scans.")

        XCTAssertEqual(NamingTemplate.read(from: prompts).template(for: other).file,
                       "names.tmpl")
    }

    func testTheNearestFolderWinsWhole() throws {
        let scans = try folder("Scans")
        let invoices = try folder("Scans/Invoices")
        try write("names/a-scans.tmpl", "# under: \(scans.path)\nName scans.")
        try write("names/b-invoices.tmpl", "# under: \(invoices.path)\nName invoices.")

        let catalogue = NamingTemplate.read(from: prompts)
        let used = catalogue.template(for: invoices.appendingPathComponent("2024"))

        // Not "Name scans. Name invoices." -- one file, as written.
        XCTAssertEqual(used.prompt, "Name invoices.")
        XCTAssertEqual(used.folder, FileOperations.canonicalPath(invoices))
        XCTAssertEqual(catalogue.template(for: scans).prompt, "Name scans.")
    }

    func testOneFileCanBeForSeveralFolders() throws {
        let one = try folder("Movies")
        let two = try folder("Archive/Movies")
        try write("names/movies.tmpl", "# under: \(one.path), \(two.path)\nName films.")

        let catalogue = NamingTemplate.read(from: prompts)

        XCTAssertEqual(catalogue.template(for: one).prompt, "Name films.")
        XCTAssertEqual(catalogue.template(for: two).prompt, "Name films.")
    }

    func testATildeMeansHome() throws {
        try write("names/home.tmpl", "# under: ~\nAt home.")

        let home = FileManager.default.homeDirectoryForCurrentUser
        XCTAssertEqual(NamingTemplate.read(from: prompts)
                        .template(for: home.appendingPathComponent("Documents")).prompt,
                       "At home.")
    }

    func testAFolderReachedThroughASymlinkIsTheSameFolder() throws {
        // /tmp is a symlink to /private/tmp on macOS; the pane may show either.
        let scans = try folder("Scans")
        let link = places.appendingPathComponent("ScansLink")
        try manager.createSymbolicLink(at: link, withDestinationURL: scans)
        try write("names/scans.tmpl", "# under: \(scans.path)\nName scans.")

        XCTAssertEqual(NamingTemplate.read(from: prompts).template(for: link).prompt,
                       "Name scans.")
    }

    func testOnlyTmplFilesAreRead() throws {
        let scans = try folder("Scans")
        try write("names/scans.txt", "# under: \(scans.path)\nNot this.")

        let catalogue = NamingTemplate.read(from: prompts)

        XCTAssertTrue(catalogue.rules.isEmpty)
        XCTAssertTrue(catalogue.problems.isEmpty, "a file that is not a .tmpl is not ours to judge")
    }

    // MARK: - Mistakes in the files

    func testAFolderFileWithoutUnderIsReportedAndUnused() throws {
        try write("names/scans.tmpl", "# undr: ~/Scans\nName scans.")

        let catalogue = NamingTemplate.read(from: prompts)

        XCTAssertTrue(catalogue.rules.isEmpty)
        let messages = catalogue.problems.filter { $0.file == "names/scans.tmpl" }.map(\.message)
        XCTAssertEqual(messages.count, 2, "the misspelling and the missing line: \(messages)")
    }

    func testASentenceWithAColonInTheNotesIsNotASetting() throws {
        try write("names.tmpl", "# For example: this is a note.\nText {{content}}")

        XCTAssertTrue(NamingTemplate.read(from: prompts).problems.isEmpty)
    }

    func testAFolderFileWithNoTextIsReportedAndUnused() throws {
        let scans = try folder("Scans")
        try write("names/scans.tmpl", "# under: \(scans.path)\n\n")

        let catalogue = NamingTemplate.read(from: prompts)

        XCTAssertTrue(catalogue.rules.isEmpty)
        XCTAssertEqual(catalogue.problems.map(\.file), ["names/scans.tmpl"])
    }

    func testTwoFilesForTheSameFolderUseTheFirstAndSaySo() throws {
        let scans = try folder("Scans")
        try write("names/a.tmpl", "# under: \(scans.path)\nFirst {{content}}")
        try write("names/b.tmpl", "# under: \(scans.path)\nSecond {{content}}")

        let catalogue = NamingTemplate.read(from: prompts)

        XCTAssertEqual(catalogue.template(for: scans).prompt, "First {{content}}")
        XCTAssertEqual(catalogue.problems.map(\.file), ["names/b.tmpl"])
    }

    // MARK: - The model follows them

    func testTheModelIsGivenTheTemplate() async throws {
        // Proof that the text reaches the model, not only that it is read: an
        // instruction the default would never produce, and its visible effect.
        let status = NameSuggester.status
        try XCTSkipUnless(status == .ready, status.explanation)

        var style = NameSuggester.Style()
        style.template = NamingTemplate.Template(body: """
            You suggest names for files from the content between BEGIN CONTENT and \
            END CONTENT. Every name you give starts with the word Scan, followed by \
            two or three words saying what the document is.

            BEGIN CONTENT
            {{content}}
            END CONTENT
            """, file: nil, folder: nil)
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
