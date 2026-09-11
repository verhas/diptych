import XCTest
@testable import Diptych

/// Editing one side of a comparison. Everything here is the model: what a
/// keystroke does to the lines, what "take this difference" replaces, what undo
/// puts back, and what reaches the disk.
@MainActor
final class DiffDocumentTests: XCTestCase {

    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("DiptychEdit-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    @discardableResult
    private func write(_ name: String, _ contents: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    private func document(_ leftText: String, _ rightText: String) async throws -> DiffDocument {
        let document = DiffDocument(pair: DiffPair(left: try write("mine.md", leftText),
                                                   right: try write("theirs.md", rightText)))
        await document.load()
        return document
    }

    private func read(_ name: String) -> String? {
        try? String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
    }

    // MARK: - One side at a time

    func testAFreshWindowIsReadOnly() async throws {
        let document = try await document("a\nb\n", "a\nc\n")

        XCTAssertNil(document.editable, "nothing can be typed into by accident")
        XCTAssertFalse(document.choiceIsMade)
    }

    func testUnlockingOneSideShutsTheOtherForGood() async throws {
        // Restrictive on purpose: editing both halves of a comparison in one
        // sitting invites losing track of which side is the one you mean.
        let document = try await document("a\nb\n", "a\nc\n")

        XCTAssertNil(document.unlock(.left))
        XCTAssertEqual(document.editable, .left)

        guard case .alreadyChosen = try XCTUnwrap(document.unlock(.right)) else {
            return XCTFail("the second padlock has to stay shut")
        }
        XCTAssertEqual(document.editable, .left, "and the choice does not move")
    }

    func testTheChoiceStaysMadeEvenAfterSaving() async throws {
        let document = try await document("a\nb\n", "a\nc\n")
        _ = document.unlock(.left)
        document.setLine(1, to: "edited")
        XCTAssertEqual(document.save(), .saved)

        guard case .alreadyChosen = try XCTUnwrap(document.unlock(.right)) else {
            return XCTFail("saving is not permission to start on the other side")
        }
    }

    func testAReadOnlyFileCannotBeUnlocked() async throws {
        let document = try await document("a\n", "b\n")
        try fm.setAttributes([.posixPermissions: 0o444],
                             ofItemAtPath: root.appendingPathComponent("mine.md").path)
        await document.load()

        guard case .notWritable(let name) = try XCTUnwrap(document.unlock(.left)) else {
            return XCTFail("said before the user has typed anything, not at save time")
        }
        XCTAssertEqual(name, "mine.md")
        XCTAssertNil(document.editable)
    }

    func testNothingCanBeEditedWhileBothSidesAreLocked() async throws {
        let document = try await document("a\nb\n", "a\nc\n")

        document.setLine(0, to: "nope")

        XCTAssertEqual(document.lines[.left], ["a", "b"])
        XCTAssertFalse(document.isDirty)
    }

    // MARK: - Typing

    func testChangingALineShowsUpInTheComparison() async throws {
        let document = try await document("a\nb\n", "a\nc\n")
        _ = document.unlock(.left)
        XCTAssertEqual(document.diff.changeStarts.count, 1)

        document.setLine(1, to: "c")

        XCTAssertTrue(document.diff.isIdentical, "the two files now agree")
        XCTAssertTrue(document.isDirty)
    }

    func testSplittingALineAtTheCaret() async throws {
        let document = try await document("one two\n", "x\n")
        _ = document.unlock(.left)

        document.splitLine(0, at: 3)

        XCTAssertEqual(document.lines[.left], ["one", " two"])
    }

    func testJoiningALineWithTheOneAbove() async throws {
        let document = try await document("one\ntwo\n", "x\n")
        _ = document.unlock(.left)

        document.joinWithPrevious(1)

        XCTAssertEqual(document.lines[.left], ["onetwo"])
    }

    func testJoiningTheFirstLineDoesNothing() async throws {
        let document = try await document("one\ntwo\n", "x\n")
        _ = document.unlock(.left)

        document.joinWithPrevious(0)

        XCTAssertEqual(document.lines[.left], ["one", "two"], "there is nothing above it")
    }

    func testDeletingALine() async throws {
        let document = try await document("one\ntwo\nthree\n", "x\n")
        _ = document.unlock(.left)

        document.deleteLine(1)

        XCTAssertEqual(document.lines[.left], ["one", "three"])
    }

    // MARK: - Which lines the gutter marks

    func testOnlyTheEditedLineIsMarked() async throws {
        let document = try await document("a\nb\nc\n", "a\nb\nc\n")
        _ = document.unlock(.left)

        document.setLine(1, to: "B")

        XCTAssertEqual(document.editedLines, [1])
    }

    func testAnInsertionDoesNotMarkEveryLineBelowIt() async throws {
        // The reason edits are found by comparing rather than by remembering
        // which line was touched: positions move, and marking everything after
        // an insertion tells the reader nothing at all.
        let document = try await document("a\nb\nc\nd\n", "x\n")
        _ = document.unlock(.left)

        document.splitLine(0, at: 0)   // an empty line appears above "a"

        XCTAssertEqual(document.editedLines, [0], "one new line, not four moved ones")
    }

    func testNothingIsMarkedOnceTheEditIsUndone() async throws {
        let document = try await document("a\nb\n", "x\n")
        _ = document.unlock(.left)
        document.setLine(0, to: "A")
        XCTAssertEqual(document.editedLines, [0])

        document.undo()

        XCTAssertTrue(document.editedLines.isEmpty)
        XCTAssertFalse(document.isDirty)
    }

    // MARK: - Taking a difference

    func testTakingARewrittenLine() async throws {
        let document = try await document("title\nmine\nend\n", "title\ntheirs\nend\n")
        _ = document.unlock(.left)

        document.takeDifference(atRow: 1)

        XCTAssertEqual(document.lines[.left], ["title", "theirs", "end"])
        XCTAssertTrue(document.diff.isIdentical)
    }

    func testTakingAWholeRunInOneGo() async throws {
        // A reader who presses this means "make this bit the same", and a run
        // of changed lines is one bit.
        let document = try await document("a\n1\n2\n3\nz\n", "a\nx\ny\nz\n")
        _ = document.unlock(.left)

        document.takeDifference(atRow: 1)

        XCTAssertEqual(document.lines[.left], ["a", "x", "y", "z"])
    }

    func testTakingLinesThisSideDoesNotHave() async throws {
        let document = try await document("a\nz\n", "a\nmiddle\nz\n")
        _ = document.unlock(.left)

        document.takeDifference(atRow: 1)

        XCTAssertEqual(document.lines[.left], ["a", "middle", "z"])
    }

    func testTakingNothingRemovesTheLine() async throws {
        // The other side has no line here, so making this bit the same means
        // deleting it. Correct, and worth being sure of.
        let document = try await document("a\nextra\nz\n", "a\nz\n")
        _ = document.unlock(.left)

        document.takeDifference(atRow: 1)

        XCTAssertEqual(document.lines[.left], ["a", "z"])
    }

    func testTakingADifferenceUndoesInOneStep() async throws {
        let document = try await document("a\n1\n2\n3\nz\n", "a\nx\ny\nz\n")
        _ = document.unlock(.left)
        document.takeDifference(atRow: 1)

        document.undo()

        XCTAssertEqual(document.lines[.left], ["a", "1", "2", "3", "z"],
                       "one button pressed, one step back")
        XCTAssertFalse(document.canUndo)
    }

    func testTakingFromTheRightWhenTheRightIsUnlocked() async throws {
        // The direction is whichever side is unlocked, which is the whole point
        // of only unlocking one.
        let document = try await document("mine\n", "theirs\n")
        _ = document.unlock(.right)

        document.takeDifference(atRow: 0)

        XCTAssertEqual(document.lines[.right], ["mine"])
        XCTAssertEqual(document.lines[.left], ["mine"], "and the locked side is untouched")
    }

    // MARK: - Undo and redo

    func testUndoAndRedoWalkBackAndForth() async throws {
        let document = try await document("a\nb\n", "x\n")
        _ = document.unlock(.left)
        document.setLine(0, to: "one")
        document.setLine(1, to: "two")

        document.undo()
        XCTAssertEqual(document.lines[.left], ["one", "b"])
        document.undo()
        XCTAssertEqual(document.lines[.left], ["a", "b"])
        XCTAssertFalse(document.canUndo)

        document.redo()
        XCTAssertEqual(document.lines[.left], ["one", "b"])
        document.redo()
        XCTAssertEqual(document.lines[.left], ["one", "two"])
    }

    func testANewEditDropsWhatWasUndone() async throws {
        let document = try await document("a\n", "x\n")
        _ = document.unlock(.left)
        document.setLine(0, to: "one")
        document.undo()

        document.setLine(0, to: "other")

        XCTAssertFalse(document.canRedo, "there is no forward any more")
    }

    // MARK: - Saving

    func testSavingWritesOnlyTheUnlockedSide() async throws {
        let document = try await document("mine\n", "theirs\n")
        _ = document.unlock(.left)
        document.setLine(0, to: "changed")

        XCTAssertEqual(document.save(), .saved)

        XCTAssertEqual(read("mine.md"), "changed\n")
        XCTAssertEqual(read("theirs.md"), "theirs\n", "the locked file is never rewritten")
        XCTAssertFalse(document.isDirty)
    }

    func testSavingWithNothingChangedDoesNotTouchTheFile() async throws {
        // Rewriting an unchanged file would move its modification date and make
        // Git report a change that is not one.
        let document = try await document("mine\n", "theirs\n")
        _ = document.unlock(.left)
        let before = try fm.attributesOfItem(atPath: root.appendingPathComponent("mine.md").path)

        XCTAssertEqual(document.save(), .nothingToDo)

        let after = try fm.attributesOfItem(atPath: root.appendingPathComponent("mine.md").path)
        XCTAssertEqual(before[.modificationDate] as? Date, after[.modificationDate] as? Date)
    }

    func testACrlfFileKeepsItsLineEndings() async throws {
        let url = root.appendingPathComponent("win.md")
        try Data("one\r\ntwo\r\n".utf8).write(to: url)
        let document = DiffDocument(pair: DiffPair(left: url,
                                                   right: try write("other.md", "x\n")))
        await document.load()
        _ = document.unlock(.left)

        document.setLine(1, to: "TWO")
        XCTAssertEqual(document.save(), .saved)

        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "one\r\nTWO\r\n",
                       "not silently converted to Unix endings")
    }

    func testAFileWithNoFinalNewlineDoesNotGainOne() async throws {
        let url = root.appendingPathComponent("bare.md")
        try Data("one\ntwo".utf8).write(to: url)
        let document = DiffDocument(pair: DiffPair(left: url,
                                                   right: try write("other.md", "x\n")))
        await document.load()
        _ = document.unlock(.left)

        document.setLine(0, to: "ONE")
        XCTAssertEqual(document.save(), .saved)

        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "ONE\ntwo")
    }

    func testSavingKeepsThePermissionsTheFileHad() async throws {
        // replaceItemAt keeps the original's metadata, which matters in a file
        // manager: losing somebody's Finder tags when they fix a typo would be
        // its own small betrayal.
        let url = try write("kept.md", "one\n")
        try fm.setAttributes([.posixPermissions: 0o640], ofItemAtPath: url.path)
        let document = DiffDocument(pair: DiffPair(left: url,
                                                   right: try write("other.md", "x\n")))
        await document.load()
        _ = document.unlock(.left)

        document.setLine(0, to: "ONE")
        XCTAssertEqual(document.save(), .saved)

        let mode = try fm.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o640)
    }

    func testAFileChangedUnderneathIsNotOverwritten() async throws {
        // Quite likely in this application: Get the Latest rewrites exactly
        // these files.
        let url = try write("shared.md", "one\n")
        let document = DiffDocument(pair: DiffPair(left: url,
                                                   right: try write("other.md", "x\n")))
        await document.load()
        _ = document.unlock(.left)
        document.setLine(0, to: "mine")

        // Somebody else writes it, two seconds later than we read it.
        try Data("theirs\n".utf8).write(to: url)
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(5)],
                             ofItemAtPath: url.path)

        guard case .changedUnderneath(let name) = document.save() else {
            return XCTFail("saving over that silently would lose their work")
        }
        XCTAssertEqual(name, "shared.md")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "theirs\n", "still theirs")
    }

    // MARK: - Ignoring spacing

    func testSpacingAloneCanBeIgnored() async throws {
        let document = try await document("one   two\n", "one two\n")
        XCTAssertFalse(document.diff.isIdentical, "truthful by default")

        document.ignoreWhitespace = true

        XCTAssertTrue(document.diff.isIdentical)
    }

    func testTheRealLineIsStillShownWhenSpacingIsIgnored() async throws {
        // Displaying tidied-up text would be lying about the file.
        let document = try await document("one   two\n", "one two\n")
        document.ignoreWhitespace = true

        XCTAssertEqual(document.diff.rows.first?.left, "one   two")
        XCTAssertEqual(document.diff.rows.first?.right, "one two")
    }

    func testIgnoringSpacingDoesNotHideRealChanges() async throws {
        let document = try await document("one   two\n", "one three\n")
        document.ignoreWhitespace = true

        XCTAssertFalse(document.diff.isIdentical)
    }
}
