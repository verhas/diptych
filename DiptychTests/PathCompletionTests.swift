import XCTest
@testable import Diptych

/// Shell-style completion for the path bar.
final class PathCompletionTests: XCTestCase {

    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("DiptychPath-\(UUID().uuidString)")
        for name in ["Downloads", "Documents", "Desktop", "music", ".hidden",
                     "alpha-one", "alpha-two"] {
            try fm.createDirectory(at: root.appendingPathComponent(name),
                                   withIntermediateDirectories: true)
        }
        try Data("x".utf8).write(to: root.appendingPathComponent("notes.txt"))
        try fm.createDirectory(at: root.appendingPathComponent("Downloads/inner"),
                               withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    private func path(_ tail: String) -> String { root.path + "/" + tail }

    func testASingleMatchCompletesAndAddsItsSeparator() {
        // The separator is what makes the next Tab complete *inside* it rather
        // than re-completing the same name.
        XCTAssertEqual(PathCompletion.complete(path("Dow"), base: root.path), path("Downloads/"))
    }

    func testSeveralMatchesExtendAsFarAsTheyAgree() {
        // "alpha-one" and "alpha-two" share "alpha-", so that is how far it
        // goes -- and no separator, because it is not a directory yet.
        XCTAssertEqual(PathCompletion.complete(path("al"), base: root.path), path("alpha-"))
    }

    func testNothingIsOfferedWhenThePrefixIsAlreadyAsFarAsItGoes() {
        // Downloads, Documents and Desktop share only the "D" already typed.
        // A shell beeps here rather than completing, and so does this.
        XCTAssertNil(PathCompletion.complete(path("D"), base: root.path))
        XCTAssertNil(PathCompletion.complete(path("Do"), base: root.path), "Downloads and Documents share only Do")
    }

    func testTrailingSlashCompletesInsideTheDirectory() {
        XCTAssertEqual(PathCompletion.complete(path("Downloads/"), base: root.path), path("Downloads/inner/"))
    }

    func testFilesAreNotOffered() {
        // The bar navigates; a file path is refused on commit anyway.
        XCTAssertNil(PathCompletion.complete(path("not"), base: root.path))
    }

    func testHiddenEntriesAppearOnlyOnceTheDotIsTyped() {
        XCTAssertNil(PathCompletion.complete(path(""), base: root.path), "no dot, no hidden folder")
        XCTAssertEqual(PathCompletion.complete(path("."), base: root.path), path(".hidden/"))
    }

    func testCompletionIsCaseInsensitiveButKeepsTheRealSpelling() {
        XCTAssertEqual(PathCompletion.complete(path("mus"), base: root.path), path("music/"))
        XCTAssertEqual(PathCompletion.complete(path("MUS"), base: root.path), path("music/"),
                       "the file system is case-insensitive; the name is not")
    }

    func testTheSuffixIsWhatTabWouldAdd() {
        XCTAssertEqual(PathCompletion.suffix(for: path("Dow"), base: root.path), "nloads/")
        XCTAssertEqual(PathCompletion.suffix(for: path("zzz"), base: root.path), "")
    }

    func testAlreadyCompleteTextOffersNothing() {
        XCTAssertNil(PathCompletion.complete(path("music/"), base: root.path),
                     "an empty directory has nothing to add")
    }

    func testValidityIsAboutDirectoriesNotFiles() {
        XCTAssertTrue(PathCompletion.isDirectory(path("Downloads"), base: root.path))
        XCTAssertFalse(PathCompletion.isDirectory(path("notes.txt"), base: root.path), "a file is not a folder")
        XCTAssertFalse(PathCompletion.isDirectory(path("nowhere"), base: root.path))
    }

    // MARK: - Relative paths

    func testABareNameIsAChildOfWhereThePaneIs() {
        // The whole point of Command-G: select all, type a child's name, go.
        XCTAssertEqual(PathCompletion.complete("Dow", base: root.path), "Downloads/")
        XCTAssertTrue(PathCompletion.isDirectory("Downloads", base: root.path))
    }

    func testDotSlashIsTheSameDirectory() {
        XCTAssertEqual(PathCompletion.complete("./Dow", base: root.path), "./Downloads/")
        XCTAssertTrue(PathCompletion.isDirectory("./Downloads", base: root.path))
    }

    func testDotDotIsTheParentNotTheRootOfTheDisk() {
        // The bug this exists for: relative text was resolved against the
        // process's working directory, which for an app launched from the
        // Finder is "/" -- so "../" went to the root of the disk.
        let inner = root.appendingPathComponent("Downloads").path

        XCTAssertEqual(PathCompletion.resolve("../", base: inner), root.path)
        XCTAssertEqual(PathCompletion.resolve("..", base: inner), root.path)
        XCTAssertNotEqual(PathCompletion.resolve("../", base: inner), "/")
    }

    func testCompletionWorksThroughTheParent() {
        let inner = root.appendingPathComponent("Downloads").path

        XCTAssertEqual(PathCompletion.complete("../mus", base: inner), "../music/")
    }

    func testCompletingLeavesRelativeTextRelative() {
        // Rewriting what was typed into an absolute path under the cursor would
        // be its own kind of surprise.
        XCTAssertEqual(PathCompletion.complete("Dow", base: root.path), "Downloads/")
        XCTAssertFalse(PathCompletion.complete("Dow", base: root.path)?.hasPrefix("/") ?? true)
    }

    func testAbsoluteAndTildePathsIgnoreTheBase() {
        XCTAssertEqual(PathCompletion.resolve("/usr/bin", base: root.path), "/usr/bin")
        XCTAssertEqual(PathCompletion.resolve("~", base: root.path), NSHomeDirectory())
    }

    func testTildeIsExpanded() {
        XCTAssertTrue(PathCompletion.isDirectory("~", base: root.path))
    }
}
