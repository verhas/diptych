import XCTest
@testable import Diptych

/// `path` in the expression language, and `apply-to:` written in it: each
/// item a script is offered for is asked the expression on its own.
final class ScriptApplyToTests: XCTestCase {

    private var folder: URL!
    private let manager = FileManager.default

    override func setUpWithError() throws {
        folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("DiptychApplyTo-\(UUID().uuidString)")
        for dir in ["repo/.git/objects", "repo/src", "Thing.app/Contents"] {
            try manager.createDirectory(at: folder.appendingPathComponent(dir),
                                        withIntermediateDirectories: true)
        }
        for file in ["repo/.git/config", "repo/.git/objects/ab", "repo/src/main.swift",
                     "repo/README.md", "notes.TXT"] {
            try Data("hello\n".utf8).write(to: folder.appendingPathComponent(file))
        }
        try manager.createSymbolicLink(atPath: folder.appendingPathComponent("to-notes").path,
                                       withDestinationPath: "notes.TXT")
    }

    override func tearDownWithError() throws {
        try? manager.removeItem(at: folder)
    }

    private func query(_ text: String) throws -> FlatQuery {
        try FlatQuery.parse(text, saved: [:]).get()
    }

    private func url(_ path: String) -> URL { folder.appendingPathComponent(path) }

    private func script(_ applyTo: String, extra: String = "")
        -> (ScriptDefinition?, [ScriptProblem]) {
        ScriptDefinition.read(URL(fileURLWithPath: "/x/s.sh"),
                              contents: "#!/bin/sh\n# apply-to: \(applyTo)\n\(extra)# call: $0 $1\n")
    }

    private func target(_ path: String) -> ScriptTarget {
        ScriptTarget(url: url(path), kind: .file)
    }

    // MARK: - path

    func testPathIsAKeyword() throws {
        guard case .primitive(.path)? = try query("path = \"*/src/*\"").expression else {
            return XCTFail("path is a test of its own")
        }
        XCTAssertTrue(FlatQuery.reservedWords.contains("path"))
        XCTAssertNotNil(FlatQuery.hint(for: "path"))
    }

    func testAPatternCrossesSlashes() throws {
        let underGit = try query("path = \"*/.git/*\"")
        XCTAssertTrue(underGit.matches(url("repo/.git/config")))
        XCTAssertTrue(underGit.matches(url("repo/.git/objects/ab")), "two levels down")
        XCTAssertFalse(underGit.matches(url("repo/src/main.swift")))
        XCTAssertFalse(underGit.matches(url("repo/.git")), "the folder itself is not under it")

        XCTAssertFalse(try query("path != \"*/.git/*\"").matches(url("repo/.git/config")))
        XCTAssertTrue(try query("path != \"*/.git/*\"").matches(url("repo/README.md")))
    }

    func testARegularExpressionOnThePath() throws {
        let q = try query("path ~ /\\/\\.git(\\/|$)/")
        XCTAssertTrue(q.matches(url("repo/.git")))
        XCTAssertTrue(q.matches(url("repo/.git/config")))
        XCTAssertFalse(q.matches(url("repo/src/main.swift")))
        XCTAssertTrue(try query("path !~ /\\.git/").matches(url("repo/src/main.swift")))
    }

    func testAnExactPathAndTheHomeFolder() throws {
        XCTAssertTrue(try query("path = \"\(url("notes.TXT").path)\"").matches(url("notes.TXT")))
        guard case .primitive(.path(.equals(let value, _)))? = try query("path = \"~/Documents/*\"")
            .expression else { return XCTFail() }
        XCTAssertEqual(value, NSHomeDirectory() + "/Documents/*")
    }

    func testTwoEndingsOfAPathCannotBothHold() throws {
        let q = try query("path = \"*.jpg\" and path = \"*.png\"")
        XCTAssertTrue(q.warnings.contains { $0.message.contains("path") })
    }

    func testTheFlatWalkCanSkipGitAndStillUsePath() throws {
        // Walking past .git is the cheap way; path says the same of each
        // item, after reading it.
        let skip = try query("directory traversed and name != \".git\", file")
        XCTAssertFalse(skip.decide(FlatSubject(url: url("repo/.git"))!).traverse)
        let filter = try query("file and path != \"*/.git/*\"")
        XCTAssertFalse(filter.decide(FlatSubject(url: url("repo/.git/config"))!).list)
        XCTAssertTrue(filter.decide(FlatSubject(url: url("repo/src/main.swift"))!).list)
    }

    // MARK: - apply-to

    func testTheOldListStillMeansWhatItSays() throws {
        let (s, problems) = script("file, directory, link")
        XCTAssertEqual(problems, [])
        XCTAssertTrue(s!.applies(to: [target("notes.TXT")]))
        XCTAssertTrue(s!.applies(to: [target("repo")]))
        XCTAssertTrue(s!.applies(to: [target("to-notes")]))
    }

    func testAnyExpression() throws {
        let (s, problems) = script("file and name = \"*.txt\" and path != \"*/.git/*\"")
        XCTAssertEqual(problems, [])
        XCTAssertTrue(s!.applies(to: [target("notes.TXT")]))
        XCTAssertFalse(s!.applies(to: [target("repo/README.md")]))
        XCTAssertFalse(s!.applies(to: [target("repo")]))
    }

    func testEveryItemIsAskedOnItsOwn() throws {
        let (s, _) = script("path != \"*/.git/*\"", extra: "# args: 1,\n")
        XCTAssertTrue(s!.applies(to: [target("repo/README.md"), target("repo/src/main.swift")]))
        XCTAssertFalse(s!.applies(to: [target("repo/README.md"), target("repo/.git/config")]))
    }

    func testALinkIsAlsoWhatItLeadsTo() throws {
        // As in the flat view: `file` takes a link to a file too.
        XCTAssertTrue(script("file").0!.applies(to: [target("to-notes")]))
        XCTAssertFalse(script("file and not link").0!.applies(to: [target("to-notes")]))
        XCTAssertTrue(script("file and not link").0!.applies(to: [target("notes.TXT")]))
    }

    func testAPackageIsOneItemNotAFolder() throws {
        XCTAssertFalse(script("directory").0!.applies(to: [target("Thing.app")]))
        XCTAssertTrue(script("file").0!.applies(to: [target("Thing.app")]))
        XCTAssertTrue(script("name = \"*.app\"").0!.applies(to: [target("Thing.app")]))
    }

    func testContentsAndDatesWork() throws {
        XCTAssertTrue(script("contains \"hello\"").0!.applies(to: [target("notes.TXT")]))
        XCTAssertFalse(script("size > 1KB").0!.applies(to: [target("notes.TXT")]))
    }

    func testAMistakeIsReportedOnItsLine() throws {
        let (s, problems) = script("file and name = ")
        XCTAssertNil(s)
        XCTAssertEqual(problems.first?.line, 2)
        XCTAssertTrue(problems.first?.message.hasPrefix("apply-to:") ?? false)
    }

    func testSavedExpressionsAreNotUsed() throws {
        // A script goes to other people; a name saved here means nothing there.
        let (s, problems) = script("jpegs")
        XCTAssertNil(s)
        XCTAssertFalse(problems.isEmpty)
    }

    func testWhatNothingCanPassIsReported() throws {
        for never in ["directory traversed", "file and directory", "size > 10MB and size < 1MB"] {
            let (s, problems) = script(never)
            XCTAssertNil(s, never)
            XCTAssertTrue(problems.first?.message.contains("never be offered") ?? false, never)
        }
    }

    func testExtensionsAreStillObeyedBesideIt() throws {
        let (s, problems) = script("file", extra: "# extensions: txt\n")
        XCTAssertEqual(problems, [])
        XCTAssertTrue(s!.applies(to: [target("notes.TXT")]))
        XCTAssertFalse(s!.applies(to: [target("repo/README.md")]))
    }

    func testNoApplyToTakesEverything() throws {
        let (s, _) = ScriptDefinition.read(URL(fileURLWithPath: "/x/s.sh"),
                                           contents: "#!/bin/sh\n# call: $0 $1\n")
        XCTAssertTrue(s!.applies(to: [target("repo")]))
        XCTAssertTrue(s!.applies(to: [target("to-notes")]))
    }
}
