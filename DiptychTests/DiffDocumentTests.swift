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
        XCTAssertTrue(document.canChooseAgain)
    }

    func testAPadlockOpenedByMistakeCanBeShutAgain() async throws {
        // Reported: needing to restart the whole comparison because of a
        // misclick is a punishment, not a safeguard.
        let document = try await document("a\nb\n", "a\nc\n")
        XCTAssertNil(document.unlock(.left))

        XCTAssertTrue(document.relock())

        XCTAssertNil(document.editable)
        XCTAssertNil(document.unlock(.right), "and the other side is now free")
        XCTAssertEqual(document.editable, .right)
    }

    func testTheOtherSideCanBeOpenedDirectlyWhileNothingIsEdited() async throws {
        let document = try await document("a\nb\n", "a\nc\n")
        _ = document.unlock(.left)

        XCTAssertNil(document.unlock(.right))

        XCTAssertEqual(document.editable, .right)
    }

    func testTheOtherSideIsShutWhileThereAreUnsavedChanges() async throws {
        // The safeguard that matters: unsaved work on one side must not be
        // abandoned by a click on the other padlock.
        let document = try await document("a\nb\n", "a\nc\n")
        _ = document.unlock(.left)
        document.setLine(1, to: "edited")

        guard case .alreadyChosen = try XCTUnwrap(document.unlock(.right)) else {
            return XCTFail("there is work to lose")
        }
        XCTAssertFalse(document.relock())
        XCTAssertEqual(document.editable, .left)
    }

    func testUndoingEverythingFreesThePadlockAgain() async throws {
        let document = try await document("a\nb\n", "a\nc\n")
        _ = document.unlock(.left)
        document.setLine(1, to: "edited")
        XCTAssertFalse(document.canChooseAgain)

        document.undo()

        XCTAssertTrue(document.canChooseAgain, "nothing came of it, so nothing is at stake")
        XCTAssertTrue(document.relock())
    }

    func testOnceSomethingIsWrittenTheChoiceIsFinal() async throws {
        // "If the user wants to modify the other side they have to save, close
        // diff again" -- so a save is the point of no return, not an edit.
        let document = try await document("a\nb\n", "a\nc\n")
        _ = document.unlock(.left)
        document.setLine(1, to: "edited")
        XCTAssertEqual(document.save(), .saved)

        XCTAssertFalse(document.canChooseAgain, "the file on disk has been touched")
        XCTAssertFalse(document.relock())
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

    // MARK: - Typing reaching the document at once

    func testTypingCountsAsAChangeStraightAway() async throws {
        // Reported: while a line still had the caret, Save and Undo were dead
        // -- and in a one-line file there was no other line to move to.
        let document = try await document("one\n", "two\n")
        _ = document.unlock(.left)

        document.typing(0, "on")

        XCTAssertTrue(document.isDirty, "so Save is live")
        XCTAssertTrue(document.canUndo, "and so is Undo")
    }

    func testTheAlignmentHoldsStillWhileALineIsBeingTyped() async throws {
        // The reason the document was not told sooner: rows shifting under a
        // moving caret. Told at once, but the comparison waits.
        let document = try await document("a\nb\nc\n", "a\nb\nc\n")
        _ = document.unlock(.left)

        document.typing(1, "")

        XCTAssertTrue(document.diff.isIdentical, "not recomputed mid-word")

        document.endLine()

        XCTAssertFalse(document.diff.isIdentical, "and recomputed once the line is done")
    }

    func testSavingWhileALineIsStillBeingTypedSavesWhatIsThere() async throws {
        let document = try await document("one\n", "two\n")
        _ = document.unlock(.left)
        document.typing(0, "typed but not left")

        XCTAssertEqual(document.save(), .saved)

        XCTAssertEqual(read("mine.md"), "typed but not left\n")
    }

    func testAWholeTypingSessionUndoesAsOneStep() async throws {
        // Not character by character: one visit to a line is one thing done.
        let document = try await document("one\n", "x\n")
        _ = document.unlock(.left)
        document.typing(0, "o")
        document.typing(0, "on")
        document.typing(0, "one two")
        document.endLine()

        document.undo()

        XCTAssertEqual(document.lines[.left], ["one"])
        XCTAssertFalse(document.canUndo)
    }

    func testEscapePutsTheLineBack() async throws {
        let document = try await document("original\n", "x\n")
        _ = document.unlock(.left)
        document.typing(0, "half-typed mistake")

        document.revertLine()

        XCTAssertEqual(document.lines[.left], ["original"])
        XCTAssertFalse(document.isDirty)
    }

    func testUndoingWhileStillInTheLineWorks() async throws {
        // Pressing Undo with the caret still in the line has to end the line
        // first, or there is nothing on the stack to undo yet.
        let document = try await document("one\n", "x\n")
        _ = document.unlock(.left)
        document.typing(0, "changed")

        document.undo()

        XCTAssertEqual(document.lines[.left], ["one"])
    }

    // MARK: - Starting again

    func testComparingTheSamePairAgainStartsFromWhatIsOnDisk() async throws {
        // Reported: SwiftUI keeps a window's state against the value it was
        // opened with, so the same comparison came back with the old undo
        // history and the old padlock open on a file that had since been saved.
        let document = try await document("one\n", "two\n")
        _ = document.unlock(.left)
        document.setLine(0, to: "edited")
        XCTAssertEqual(document.save(), .saved)
        XCTAssertTrue(document.canUndo)

        await document.load()

        XCTAssertNil(document.editable, "both sides locked again")
        XCTAssertTrue(document.canChooseAgain)
        XCTAssertFalse(document.canUndo, "and no history from last time")
        XCTAssertEqual(document.lines[.left], ["edited"], "starting from what was saved")
        XCTAssertFalse(document.isDirty)
    }

    func testReloadingAfterAnOutsideChangeKeepsTheChosenSide() async throws {
        // The other direction: re-reading because the file moved underneath is
        // not the same as opening the comparison afresh.
        let document = try await document("one\n", "two\n")
        _ = document.unlock(.left)

        await document.reload()

        XCTAssertEqual(document.editable, .left)
    }

    // MARK: - The longest line

    func testTheLongestLineIsKnownForScrolling() async throws {
        // The columns have to be at least this wide before there is anything
        // for a horizontal scroller to reach.
        let document = try await document("short\n", "a much longer line over here\n")

        XCTAssertEqual(document.longestLine, 28)
    }
}

extension DiffDocumentTests {

    // MARK: - Finishing a clash that was set aside

    private func keptCopyPair(original: String = "chapter3.md",
                              copy: String = "chapter3 (my version).md")
        async throws -> DiffDocument {
        let document = DiffDocument(pair: DiffPair(left: try write(copy, "mine\n"),
                                                   right: try write(original, "theirs\n")))
        await document.load()
        return document
    }

    func testAKeptCopyIsRecognisedOnEitherSide() {
        let folder = URL(fileURLWithPath: "/work")
        let original = folder.appendingPathComponent("chapter3.md")
        let copy = folder.appendingPathComponent("chapter3 (my version).md")

        XCTAssertTrue(DiffDocument.isKeptCopy(of: original, copy))
        XCTAssertFalse(DiffDocument.isKeptCopy(of: copy, original), "not the other way round")
    }

    func testASecondKeptCopyIsRecognisedToo() {
        // A second clash on the same file makes "(my version)-1".
        let folder = URL(fileURLWithPath: "/work")
        XCTAssertTrue(DiffDocument.isKeptCopy(of: folder.appendingPathComponent("a.md"),
                                              folder.appendingPathComponent("a (my version)-1.md")))
    }

    func testUnrelatedFilesAreNotAKeptCopy() {
        let folder = URL(fileURLWithPath: "/work")
        XCTAssertFalse(DiffDocument.isKeptCopy(of: folder.appendingPathComponent("a.md"),
                                               folder.appendingPathComponent("b (my version).md")))
        XCTAssertFalse(DiffDocument.isKeptCopy(of: folder.appendingPathComponent("a.md"),
                                               folder.appendingPathComponent("a (my version).txt")),
                       "a different kind of file is a different file")
        XCTAssertFalse(DiffDocument.isKeptCopy(of: folder.appendingPathComponent("a.md"),
                                               URL(fileURLWithPath: "/elsewhere/a (my version).md")),
                       "and one somewhere else cannot take its place")
    }

    func testItIsOfferedWithoutEditingAnything() async throws {
        // "Drop theirs, mine stands as it is" is a decision like any other --
        // and the commonest one after keeping a copy in the first place.
        let document = try await keptCopyPair()

        XCTAssertEqual(document.keptCopySide, .left)
        XCTAssertTrue(document.canReplaceOriginal, "no edit required")
        XCTAssertEqual(document.originalName, "chapter3.md")
    }

    func testEditingTheKeptCopyStillOffersIt() async throws {
        let document = try await keptCopyPair()
        _ = document.unlock(.left)

        document.setLine(0, to: "my settled version")

        XCTAssertTrue(document.canReplaceOriginal)
    }

    func testItIsWithheldWhileTheOtherSideHasUnsavedWork() async throws {
        // That side is about to go to the Trash, and it would take the unsaved
        // work with it.
        let document = try await keptCopyPair()
        _ = document.unlock(.right)
        document.setLine(0, to: "editing the original instead")

        XCTAssertFalse(document.canReplaceOriginal)

        document.undo()
        XCTAssertTrue(document.canReplaceOriginal, "and offered again once there is none")
    }

    func testOrdinaryFilesNeverOfferIt() async throws {
        let document = try await document("a\n", "b\n")
        _ = document.unlock(.left)
        document.setLine(0, to: "changed")

        XCTAssertNil(document.keptCopySide)
        XCTAssertFalse(document.canReplaceOriginal)
    }

    func testReplacingSavesTakesTheNameAndTrashesTheOld() async throws {
        let document = try await keptCopyPair()
        _ = document.unlock(.left)
        document.typing(0, "my settled version")

        let outcome = await document.replaceOriginal()
        XCTAssertEqual(outcome, .done)

        XCTAssertEqual(read("chapter3.md"), "my settled version\n",
                       "saved, and under the original name")
        XCTAssertNil(read("chapter3 (my version).md"), "the copy is gone")
        XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent("chapter3 (my version).md").path))
    }

    func testReplacingAnUneditedCopyDitchesTheOtherVersion() async throws {
        // Nothing taken from the shared version, which is the whole point of
        // this particular press.
        let document = try await keptCopyPair()

        let outcome = await document.replaceOriginal()
        XCTAssertEqual(outcome, .done)

        XCTAssertEqual(read("chapter3.md"), "mine\n", "mine, untouched, under their name")
        XCTAssertNil(read("chapter3 (my version).md"))
    }

    func testReplacingOrdinaryFilesIsRefused() async throws {
        let document = try await document("a\n", "b\n")

        let outcome = await document.replaceOriginal()

        XCTAssertEqual(outcome, .notApplicable)
        XCTAssertEqual(read("mine.md"), "a\n")
        XCTAssertEqual(read("theirs.md"), "b\n")
    }

    func testReplacingWorksAfterTheCopyWasAlreadySaved() async throws {
        // Saving and then finishing is two presses of two different buttons,
        // and the second one still has work to do.
        let document = try await keptCopyPair()
        _ = document.unlock(.left)
        document.setLine(0, to: "my settled version")
        XCTAssertEqual(document.save(), .saved)
        XCTAssertTrue(document.canReplaceOriginal)

        let outcome = await document.replaceOriginal()
        XCTAssertEqual(outcome, .done)

        XCTAssertEqual(read("chapter3.md"), "my settled version\n")
    }
}

/// How far sideways the two columns are allowed to go.
///
/// Kept in an object rather than in view state because a scroll-wheel monitor
/// outlives a layout pass -- and reading the widths as they were rather than as
/// they are is what made a horizontal wheel do nothing and shift-and-wheel snap
/// back to the left.
@MainActor
final class SidewaysStateTests: XCTestCase {

    func testNothingScrollsUntilThereIsSomethingOutOfSight() {
        let state = SidewaysState()

        XCTAssertFalse(state.isScrollable, "and with no travel, no wheel can move it")
        state.move(by: -100)
        XCTAssertEqual(state.offset, 0)
    }

    func testWrappedTextNeverScrollsSideways() {
        let state = SidewaysState()
        state.layout(viewport: 400, content: 400, wraps: true)

        XCTAssertFalse(state.isScrollable)
    }

    func testAWheelMovesItWithinItsTravel() {
        let state = SidewaysState()
        state.layout(viewport: 400, content: 1000, wraps: false)

        state.move(by: -100)
        XCTAssertEqual(state.offset, 100)

        state.move(by: -10_000)
        XCTAssertEqual(state.offset, 600, "and no further than there is to go")

        state.move(by: 10_000)
        XCTAssertEqual(state.offset, 0, "nor back past the beginning")
    }

    func testAWiderWindowPullsTheColumnsBack() {
        // Otherwise the text stays scrolled off to the side with nothing there.
        let state = SidewaysState()
        state.layout(viewport: 400, content: 1000, wraps: false)
        state.move(by: -600)
        XCTAssertEqual(state.offset, 600)

        state.layout(viewport: 900, content: 1000, wraps: false)

        XCTAssertEqual(state.offset, 100)
    }

    func testTheLayoutIsWhatMakesItScrollable() {
        // The bug in one line: without the widths, travel is zero and every
        // movement is clamped to the far left.
        let state = SidewaysState()
        state.moveTo(300)
        XCTAssertEqual(state.offset, 0)

        state.layout(viewport: 400, content: 1000, wraps: false)
        state.moveTo(300)

        XCTAssertEqual(state.offset, 300)
    }
}
