import XCTest
@testable import Diptych

/// Reading `git status --porcelain=v2 -z`.
///
/// The parsing is where the traps are: the format is NUL-separated but a record
/// is not always one field, and paths may contain spaces, so columns cannot be
/// split on whitespace and taken by index.
final class GitStatusTests: XCTestCase {

    /// Real output shape, with NULs where git puts them.
    private func output(_ records: [String]) -> String {
        records.joined(separator: "\0") + "\0"
    }

    func testTheBranchHeaderIsRead() {
        let status = GitStatus.parse(output([
            "# branch.oid b0ff678e31085a647beb97dcab93050656dd6be6",
            "# branch.head main",
            "# branch.upstream origin/main",
            "# branch.ab +2 -3",
        ]))

        XCTAssertEqual(status.branch, "main")
        XCTAssertEqual(status.upstream, "origin/main")
        XCTAssertEqual(status.ahead, 2, "commits here that the shared copy does not have")
        XCTAssertEqual(status.behind, 3, "and the other way round")
    }

    func testADetachedHeadHasNoBranchName() {
        let status = GitStatus.parse(output(["# branch.head (detached)"]))
        XCTAssertNil(status.branch)
    }

    func testNoUpstreamLeavesTheCountsAtZero() {
        // A repository with no shared copy yet: git prints no branch.ab line.
        let status = GitStatus.parse(output(["# branch.head main"]))
        XCTAssertEqual(status.ahead, 0)
        XCTAssertEqual(status.behind, 0)
        XCTAssertNil(status.upstream)
    }

    func testUntrackedAndChangedAndAdded() {
        let status = GitStatus.parse(output([
            "? scratch.txt",
            "1 .M N... 100644 100644 100644 abc def chapter3.md",
            "1 A. N... 000000 100644 100644 abc def appendix.md",
        ]))

        XCTAssertEqual(status.states["scratch.txt"], .untracked)
        XCTAssertEqual(status.states["chapter3.md"], .changed)
        XCTAssertEqual(status.states["appendix.md"], .added,
                       "staged as new is the one that means new-and-tracked")
    }

    func testADeletionIsItsOwnState() {
        // Not "changed": a file the user knows they deleted, listed in the send
        // dialog as changed, reads as a mistake.
        let status = GitStatus.parse(output([
            "1 .D N... 100644 100644 000000 abc def gone.md",
            "1 D. N... 100644 000000 000000 abc def staged-gone.md",
        ]))

        XCTAssertEqual(status.states["gone.md"], .deleted)
        XCTAssertEqual(status.states["staged-gone.md"], .deleted,
                       "whether the removal is staged or not, it is still a removal")
    }

    func testADeletionRanksWithAChangeForAFolder() {
        var status = GitStatus()
        status.states["chapter/one.md"] = .deleted
        XCTAssertEqual(status.state(for: URL(fileURLWithPath: "/repo/chapter"),
                                    root: URL(fileURLWithPath: "/repo")), .deleted)
    }

    func testAConflictIsReadFromTheUnmergedRecord() {
        let status = GitStatus.parse(output([
            "u UU N... 100644 100644 100644 100644 aaa bbb ccc chapter3.md",
        ]))
        XCTAssertEqual(status.states["chapter3.md"], .conflicted)
    }

    func testARenameConsumesItsSecondField() {
        // A "2" record is followed by the original path as a *separate*
        // NUL-terminated field. Splitting naively leaves that path posing as a
        // record of its own -- and since it starts with neither ? nor 1, it
        // would be silently dropped, taking the next real record with it.
        let status = GitStatus.parse(output([
            "2 R. N... 100644 100644 100644 abc def R100 new-name.md",
            "old-name.md",
            "? after-the-rename.txt",
        ]))

        XCTAssertEqual(status.states["new-name.md"], .changed)
        XCTAssertNil(status.states["old-name.md"], "the original path is not a record")
        XCTAssertEqual(status.states["after-the-rename.txt"], .untracked,
                       "and the record after the rename is still read")
    }

    func testPathsWithSpacesSurvive() {
        let status = GitStatus.parse(output([
            "1 .M N... 100644 100644 100644 abc def my notes/chapter one.md",
            "? another file.txt",
        ]))

        XCTAssertEqual(status.states["my notes/chapter one.md"], .changed)
        XCTAssertEqual(status.states["another file.txt"], .untracked)
    }

    func testIgnoredEntriesAreNotAskedForAndNotRecorded() {
        // --ignored is deliberately not passed. If one arrives anyway it must
        // not become a state, since ignored files are drawn normally.
        let status = GitStatus.parse(output(["! build/output.o"]))
        XCTAssertTrue(status.states.isEmpty)
    }

    func testEmptyOutputIsACleanRepository() {
        XCTAssertTrue(GitStatus.parse("").states.isEmpty)
    }

    // MARK: - Rolling up to what the pane draws

    func testAFolderTakesTheStrongestStateInside() {
        // The pane shows folders, and what is inside them may never be looked
        // at, so a folder holding changes must not look clean.
        var status = GitStatus()
        status.states["chapter/one.md"] = .changed
        status.states["chapter/two.md"] = .untracked
        let root = URL(fileURLWithPath: "/repo")

        XCTAssertEqual(status.state(for: URL(fileURLWithPath: "/repo/chapter"), root: root),
                       .changed)
    }

    func testAConflictOutranksEverythingElse() {
        var status = GitStatus()
        status.states["chapter/one.md"] = .changed
        status.states["chapter/two.md"] = .conflicted
        let root = URL(fileURLWithPath: "/repo")

        XCTAssertEqual(status.state(for: URL(fileURLWithPath: "/repo/chapter"), root: root),
                       .conflicted)
    }

    func testAFileWithNothingToSayIsClean() {
        let status = GitStatus()
        XCTAssertEqual(status.state(for: URL(fileURLWithPath: "/repo/x.md"),
                                    root: URL(fileURLWithPath: "/repo")), .clean)
    }

    func testAPathOutsideTheRepositoryIsClean() {
        var status = GitStatus()
        status.states["x.md"] = .changed
        XCTAssertEqual(status.state(for: URL(fileURLWithPath: "/elsewhere/x.md"),
                                    root: URL(fileURLWithPath: "/repo")), .clean)
    }

    func testAPrefixThatOnlyLooksSimilarIsNotInside() {
        // "/repo-backup" starts with "/repo" as text but is a different folder.
        var status = GitStatus()
        status.states["x.md"] = .changed
        XCTAssertEqual(status.state(for: URL(fileURLWithPath: "/repo-backup/x.md"),
                                    root: URL(fileURLWithPath: "/repo")), .clean)
    }

    // MARK: - Out of date, and what a folder says

    func testAFolderListsEverythingInsideItStrongestFirst() {
        var status = GitStatus()
        status.states = [
            "book/one.md": .added,
            "book/two.md": .contested,
            "book/three.md": .changed,
            "book/four.md": .stale,
        ]
        let root = URL(fileURLWithPath: "/repo")

        let found = status.states(for: root.appendingPathComponent("book"), root: root)

        XCTAssertEqual(found, [.contested, .stale, .changed, .added],
                       "red, purple, blue, green")
    }

    func testAFileListsOnlyItself() {
        var status = GitStatus()
        status.states = ["book/one.md": .stale, "book/one.md.bak": .changed]
        let root = URL(fileURLWithPath: "/repo")

        XCTAssertEqual(status.states(for: root.appendingPathComponent("book/one.md"), root: root),
                       [.stale], "and not its neighbour, whose name it is a prefix of")
    }

    func testOutOfDateOutranksChangedButNotAClash() {
        // A folder holding work you are about to waste matters more than one
        // holding work you have already done -- but less than one you cannot
        // send at all.
        XCTAssertEqual(GitStatus.stronger(.stale, .changed), .stale)
        XCTAssertEqual(GitStatus.stronger(.stale, .added), .stale)
        XCTAssertEqual(GitStatus.stronger(.stale, .contested), .contested)
        XCTAssertEqual(GitStatus.stronger(.stale, .conflicted), .conflicted)
    }

    func testTheWordsAreWorthReading() {
        // "also changed" was reported as too mild for a file that cannot be
        // sent until somebody decides something.
        XCTAssertEqual(GitState.contested.title, "clash")
        XCTAssertEqual(GitState.stale.title, "out of date")
        XCTAssertNotNil(GitState.stale.explanation)
    }
}
