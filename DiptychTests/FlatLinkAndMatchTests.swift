import XCTest
@testable import Diptych

/// `link` in the expression language, and the language used outside the
/// flat view: `matches`, on a subject, a pane row or any path.
final class FlatLinkAndMatchTests: XCTestCase {

    private var folder: URL!
    private let manager = FileManager.default

    override func setUpWithError() throws {
        folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("DiptychLinks-\(UUID().uuidString)")
        try manager.createDirectory(at: folder.appendingPathComponent("dir"),
                                    withIntermediateDirectories: true)
        try Data("hello\n".utf8).write(to: folder.appendingPathComponent("plain.txt"))
        try manager.createSymbolicLink(atPath: folder.appendingPathComponent("to-file").path,
                                       withDestinationPath: "plain.txt")
        try manager.createSymbolicLink(atPath: folder.appendingPathComponent("to-dir").path,
                                       withDestinationPath: "dir")
        try manager.createSymbolicLink(atPath: folder.appendingPathComponent("to-nothing").path,
                                       withDestinationPath: "gone.txt")
        // to-to-nothing -> to-nothing -> gone.txt; round-a -> round-b -> round-a;
        // self -> self; into-loop -> round-a.
        for (name, target) in [("to-to-nothing", "to-nothing"), ("round-a", "round-b"),
                               ("round-b", "round-a"), ("self", "self"),
                               ("into-loop", "round-a")] {
            try manager.createSymbolicLink(atPath: folder.appendingPathComponent(name).path,
                                           withDestinationPath: target)
        }
    }

    override func tearDownWithError() throws {
        try? manager.removeItem(at: folder)
    }

    private func query(_ text: String) throws -> FlatQuery {
        try FlatQuery.parse(text, saved: [:]).get()
    }

    private func url(_ name: String) -> URL { folder.appendingPathComponent(name) }

    private func subject(_ name: String, directory: Bool = false, link: Bool = false) -> FlatSubject {
        FlatSubject(url: URL(fileURLWithPath: "/nowhere/\(name)"), name: name,
                    isDirectory: directory, isLink: link, size: 1, mode: 0o644,
                    owner: "peter", group: "staff", created: Date(), modified: Date())
    }

    // MARK: - link

    func testLinkParsesAndIsAKeyword() throws {
        guard case .primitive(.link)? = try query("LINK").expression else {
            return XCTFail("link is a test of its own")
        }
        XCTAssertTrue(FlatQuery.primitives.contains("link"))
        XCTAssertNotNil(FlatQuery.hint(for: "link"))
        XCTAssertTrue(FlatQuery.reservedWords.contains("link"),
                      "a saved expression must not be called link")
    }

    func testLinkIsNotAKind() throws {
        // It says nothing about folders, so the flat view keeps walking them.
        XCTAssertFalse(try query("link").namesKinds)
    }

    func testLinkHoldsForSymbolicLinksOnly() throws {
        let link = try query("link")
        XCTAssertTrue(link.matches(subject("a", link: true)))
        XCTAssertTrue(link.matches(subject("d", directory: true, link: true)))
        XCTAssertFalse(link.matches(subject("b")))
        XCTAssertFalse(try query("not link").matches(subject("a", link: true)))
    }

    func testLinkOnTheDisk() throws {
        let link = try query("link")
        XCTAssertTrue(link.matches(url("to-file")))
        XCTAssertTrue(link.matches(url("to-dir")))
        XCTAssertTrue(link.matches(url("to-nothing")), "a broken link is still a link")
        XCTAssertFalse(link.matches(url("plain.txt")))
        XCTAssertFalse(link.matches(url("dir")))
    }

    func testALinkIsAlsoWhatItLeadsTo() throws {
        XCTAssertTrue(try query("link and file").matches(url("to-file")))
        XCTAssertTrue(try query("link and directory").matches(url("to-dir")))
        XCTAssertFalse(try query("link and directory").matches(url("to-file")))
    }

    func testTheFlatWalkListsLinks() throws {
        let link = try query("link")
        XCTAssertTrue(link.decide(FlatSubject(url: url("to-file"))!).list)
        XCTAssertFalse(link.decide(FlatSubject(url: url("plain.txt"))!).list)
    }

    // MARK: - matches, outside the flat view

    func testAnEmptyExpressionMatchesEverything() throws {
        XCTAssertTrue(try query("").matches(subject("x")))
        XCTAssertTrue(try query("").matches(subject("d", directory: true)))
    }

    func testAFolderIsAskedTheExpressionItself() throws {
        // The flat view lists every folder for an expression about files;
        // matching asks the folder the question like anything else.
        let apps = try query("name = \"*.app\"")
        XCTAssertTrue(apps.matches(subject("Mail.app", directory: true)))
        XCTAssertFalse(apps.matches(subject("Documents", directory: true)))
        XCTAssertTrue(apps.decide(subject("Documents", directory: true)).list,
                      "while the walk still lists it")
    }

    func testAFolderIsListedNotTraversed() throws {
        let folder = subject("d", directory: true)
        XCTAssertTrue(try query("directory").matches(folder))
        XCTAssertTrue(try query("directory listed").matches(folder))
        XCTAssertFalse(try query("directory traversed").matches(folder))
    }

    func testAPathThatIsNotThereMatchesNothing() throws {
        XCTAssertNil(FlatSubject(url: url("absent")))
        XCTAssertFalse(try query("not link").matches(url("absent")))
    }

    func testAPathIsReadWithWhatTheExpressionNeeds() throws {
        let subject = try XCTUnwrap(FlatSubject(url: url("plain.txt")))
        XCTAssertEqual(subject.size, 6)
        XCTAssertEqual(subject.owner, NSUserName())
        XCTAssertTrue(try query("size = 6 and owner = \"\(NSUserName())\"").matches(subject))
        XCTAssertTrue(try query("contains \"hello\"").matches(url("plain.txt")))
    }

    // MARK: - link broken, link loop

    func testTheWordsParseOnlyAfterLink() throws {
        guard case .primitive(.linkEnd(.broken, negated: false))? = try query("link broken").expression,
              case .primitive(.linkEnd(.loop, negated: true))? = try query("LINK NOT LOOP").expression
        else { return XCTFail("link broken and link not loop are tests of their own") }
        XCTAssertFalse(FlatQuery.reservedWords.contains("broken"))
        XCTAssertFalse(FlatQuery.reservedWords.contains("loop"))
        XCTAssertNotNil(FlatQuery.hint(for: "broken"))
        // `link not x` is still a mistake: only broken and loop follow.
        XCTAssertThrowsError(try query("link not file"))
    }

    func testBrokenIsWhatLeadsNowhere() throws {
        let broken = try query("link broken")
        for name in ["to-nothing", "to-to-nothing", "round-a", "self", "into-loop"] {
            XCTAssertTrue(broken.matches(url(name)), name)
        }
        for name in ["to-file", "to-dir", "plain.txt", "dir"] {
            XCTAssertFalse(broken.matches(url(name)), name)
        }
    }

    func testLoopIsWhatGoesRound() throws {
        let loop = try query("link loop")
        for name in ["round-a", "round-b", "self", "into-loop"] {
            XCTAssertTrue(loop.matches(url(name)), name)
        }
        for name in ["to-nothing", "to-to-nothing", "to-file", "plain.txt"] {
            XCTAssertFalse(loop.matches(url(name)), name)
        }
    }

    func testTheShortFormsKeepToLinks() throws {
        // `link not broken` is `link and not link broken`; `not link broken`
        // takes every plain file too.
        let names = ["to-file", "to-dir", "to-nothing", "round-a", "plain.txt", "dir"]
        func passing(_ text: String) throws -> Set<String> {
            let q = try query(text)
            return Set(names.filter { q.matches(url($0)) })
        }
        XCTAssertEqual(try passing("link not broken"), ["to-file", "to-dir"])
        XCTAssertEqual(try passing("link not broken"), try passing("link and not link broken"))
        XCTAssertEqual(try passing("link not loop"), ["to-file", "to-dir", "to-nothing"])
        XCTAssertEqual(try passing("link not loop"), try passing("link and not link loop"))
        XCTAssertEqual(try passing("not link broken"), ["to-file", "to-dir", "plain.txt", "dir"])
        XCTAssertEqual(try passing("link broken and link not loop"), ["to-nothing"])
    }

    func testABrokenLinkIsStillAFile() throws {
        // Not a folder, so `file`: `link and (file or directory)` is every link.
        XCTAssertTrue(try query("link and (file or directory)").matches(url("to-nothing")))
    }

    func testTheFlatWalkFindsThem() throws {
        let broken = try query("link broken")
        XCTAssertTrue(broken.decide(FlatSubject(url: url("round-a"))!).list)
        XCTAssertFalse(broken.decide(FlatSubject(url: url("to-file"))!).list)
    }

    func testCompletionOffersThem() {
        XCTAssertTrue(FlatQuery.completions(in: "link ", at: 5).words.contains("broken"))
        XCTAssertEqual(FlatQuery.completions(in: "link not ", at: 9).words, ["broken", "loop"])
    }

    func testAScriptCanAskForThem() throws {
        let (script, problems) = ScriptDefinition.read(
            URL(fileURLWithPath: "/x/s.sh"),
            contents: "#!/bin/sh\n# apply-to: link broken\n# args: 1,\n# call: $0 $@\n")
        XCTAssertEqual(problems, [])
        let item = { ScriptTarget(url: self.url($0), kind: .link) }
        XCTAssertTrue(script!.applies(to: [item("to-nothing"), item("self")]))
        XCTAssertFalse(script!.applies(to: [item("to-nothing"), item("to-file")]))
    }
}
