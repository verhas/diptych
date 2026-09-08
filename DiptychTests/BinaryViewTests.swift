import XCTest
@testable import Diptych

/// The hex editor's model.
///
/// The parts worth pinning down are the ones with teeth: that an untouched byte
/// is never written, that typing produces the value the user meant, and that a
/// short last line does not walk off the end of the file.
@MainActor
final class BinaryViewTests: XCTestCase {

    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("DiptychBinary-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    private func makeFile(_ bytes: [UInt8], _ name: String = "data.bin") throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data(bytes).write(to: url)
        return url
    }

    /// The model reads the file off the main actor, so the tests have to wait
    /// for it the way the window does.
    private func model(_ bytes: [UInt8]) async throws -> BinaryViewModel {
        let model = BinaryViewModel(url: try makeFile(bytes))
        while model.isLoading { await Task.yield() }
        return model
    }

    // MARK: - Reading

    func testRowsCoverEveryByteIncludingAShortLastLine() async throws {
        let model = try await model(Array(0 ..< 20))
        model.bytesPerLine = 8

        XCTAssertEqual(model.rowCount, 3, "20 bytes at 8 per line is three lines")
        XCTAssertEqual(model.offsets(inRow: 2), 16 ..< 20, "the last line is short")
        XCTAssertEqual(model.address(ofRow: 1), "0008")
    }

    func testOnlySafeCharactersAreDrawn() async throws {
        // A control character has no glyph and the C1 range renders as anything
        // at all, so everything outside printable ASCII becomes a dot.
        let model = try await model([0x41, 0x00, 0x0A, 0x7F, 0x80, 0xFF, 0x7E])

        XCTAssertEqual((0 ..< 7).map { model.character(at: $0) },
                       ["A", ".", ".", ".", ".", ".", "~"])
    }

    func testBytesAreWrittenInTheChosenBase() async throws {
        let model = try await model([0x00, 0x0F, 0xFF])

        XCTAssertEqual((0 ..< 3).map { model.text(at: $0) }, ["00", "0F", "FF"])
        model.decimal = true
        XCTAssertEqual((0 ..< 3).map { model.text(at: $0) }, ["  0", " 15", "255"])
    }

    // MARK: - Typing

    func testTwoHexDigitsMakeAByteAndAdvance() async throws {
        let model = try await model([0x00, 0x00])

        model.type("4")
        XCTAssertEqual(model.byte(at: 0), 0x04, "a half-typed byte is already visible")
        XCTAssertEqual(model.cursor, 0, "and does not advance until it is whole")
        model.type("1")
        XCTAssertEqual(model.byte(at: 0), 0x41)
        XCTAssertEqual(model.cursor, 1)
    }

    func testDecimalCommitsAsSoonAsNoFurtherDigitCouldFit() async throws {
        // 99 is complete: 99x cannot be a byte. 25 is not: 255 can.
        let model = try await model([0, 0, 0])
        model.decimal = true

        model.type("9"); model.type("9")
        XCTAssertEqual(model.byte(at: 0), 99)
        XCTAssertEqual(model.cursor, 1, "99 cannot grow, so it is done")

        model.type("2"); model.type("5")
        XCTAssertEqual(model.cursor, 1, "25 could still become 255")
        model.type("5")
        XCTAssertEqual(model.byte(at: 1), 255)
        XCTAssertEqual(model.cursor, 2)
    }

    func testADigitThatWouldOverflowStartsTheNextByte() async throws {
        // 266 is not a byte, so 26 is committed as soon as the third digit
        // could only overflow, and that digit begins the byte after it.
        let model = try await model([0, 0])
        model.decimal = true

        model.type("2"); model.type("6"); model.type("6")

        XCTAssertEqual(model.byte(at: 0), 26, "never wrapped or truncated to 6")
        XCTAssertEqual(model.byte(at: 1), 6)
    }

    func testTypingPastTheLastByteRetypesItRatherThanRunningOff() async throws {
        let model = try await model([0])

        model.type("4"); model.type("1")
        XCTAssertEqual(model.byte(at: 0), 0x41)
        XCTAssertEqual(model.cursor, 0, "there is nowhere to advance to")

        model.type("7")
        XCTAssertEqual(model.byte(at: 0), 0x07, "so the digit starts that byte again")
        XCTAssertEqual(model.count, 1, "and the file never grows")
    }

    func testNonDigitsAreIgnoredInTheirBase() async throws {
        let model = try await model([0x00])

        model.type("g")
        XCTAssertFalse(model.hasEdits, "g is not a hex digit")
        model.decimal = true
        model.type("f")
        XCTAssertFalse(model.hasEdits, "nor is f a decimal one")
    }

    // MARK: - Moving

    func testArrowsStepAByteAndALine() async throws {
        let model = try await model(Array(0 ..< 64))
        model.bytesPerLine = 16
        model.moveCursor(to: 20)

        model.moveCursor(by: 1)
        XCTAssertEqual(model.cursor, 21)
        model.moveCursor(by: -1)
        XCTAssertEqual(model.cursor, 20)
        model.moveCursor(by: model.columns)
        XCTAssertEqual(model.cursor, 36, "down is one line, whatever the line width")
        model.moveCursor(by: -model.columns)
        XCTAssertEqual(model.cursor, 20)
    }

    func testMovingIsMeasuredInTheWidthActuallyDrawn() async throws {
        // A 20-byte file at 64 per line is drawn 20 wide, so "down a line" has
        // to step 20 -- past the end, and so clamped -- not 64.
        let model = try await model(Array(0 ..< 20))
        model.bytesPerLine = 64
        XCTAssertEqual(model.columns, 20)

        model.moveCursor(to: 0)
        model.moveCursor(by: model.columns)
        XCTAssertEqual(model.cursor, 19, "clamped to the last byte, not left at 0")
    }

    // MARK: - Change tracking

    func testTypingBackTheOriginalValueClearsTheChangeCount() async throws {
        // The footer counted every byte that had been *typed*, not every byte
        // that differed, so restoring a value by hand left it claiming
        // "1 changed" over a byte that was already black again.
        let model = try await model([0x41, 0x42])

        model.type("F"); model.type("F")
        XCTAssertEqual(model.changedCount, 1)

        model.moveCursor(to: 0)
        model.type("4"); model.type("1")

        XCTAssertEqual(model.changedCount, 0)
        XCTAssertFalse(model.hasEdits, "and Save must go back to being disabled")
        XCTAssertTrue(model.runs.isEmpty, "with nothing left to write")
    }

    func testDeleteUndoesTheByteJustTyped() async throws {
        // A finished byte leaves the cursor on the *next* one, so reverting
        // strictly under the cursor undid a byte the user had never touched and
        // left the one they had just typed standing.
        let model = try await model([0x41, 0x42, 0x43])

        model.type("F"); model.type("F")
        XCTAssertEqual(model.cursor, 1, "the cursor has moved on")

        model.revert()

        XCTAssertEqual(model.byte(at: 0), 0x41, "the byte just typed is the one restored")
        XCTAssertFalse(model.hasEdits)
        XCTAssertEqual(model.cursor, 0)
    }

    func testRevertingWorksWithTheCursorOnTheChangedByte() async throws {
        // Clicking the red byte and pressing Delete: the cursor is *on* the
        // edit rather than after it, which is the other way round from typing.
        let model = try await model([0x41, 0x42, 0x43])
        model.moveCursor(to: 2)
        model.type("F"); model.type("F")

        model.moveCursor(to: 2)
        XCTAssertTrue(model.isChanged(at: 2))
        model.revert()

        XCTAssertEqual(model.byte(at: 2), 0x43)
        XCTAssertFalse(model.hasEdits)
    }

    func testRevertingLeavesUnrelatedEditsAlone() async throws {
        let model = try await model([0x41, 0x42, 0x43])
        model.moveCursor(to: 0); model.type("F"); model.type("F")
        model.moveCursor(to: 2); model.type("E"); model.type("E")

        model.moveCursor(to: 2)
        model.revert()

        XCTAssertEqual(model.byte(at: 2), 0x43)
        XCTAssertEqual(model.byte(at: 0), 0xFF, "the other edit stands")
        XCTAssertEqual(model.changedCount, 1)
    }

    func testDeleteCancelsAHalfTypedByte() async throws {
        let model = try await model([0x41])

        model.type("F")
        XCTAssertEqual(model.byte(at: 0), 0x0F)

        model.revert()

        XCTAssertEqual(model.byte(at: 0), 0x41, "the digits and their value both go")
        XCTAssertFalse(model.hasEdits)
    }

    func testRowsAreNeverWiderThanTheFile() async throws {
        // A 28-byte file at 64 bytes a line is one row of 28. Laying it out as
        // 64 columns is what pushed the character column off to the right.
        let model = try await model(Array(repeating: 0x41, count: 28))
        model.bytesPerLine = 64

        XCTAssertEqual(model.columns, 28)
        XCTAssertEqual(model.rowCount, 1)
        XCTAssertEqual(model.rowSpan(0), 0 ..< 28, "no empty columns to pad past")

        model.bytesPerLine = 16
        XCTAssertEqual(model.columns, 16)
        XCTAssertEqual(model.rowCount, 2)
        XCTAssertEqual(model.offsets(inRow: 1), 16 ..< 28, "the short line is still short")
        XCTAssertEqual(model.rowSpan(1), 16 ..< 32, "but it pads to keep the columns aligned")
    }

    func testTypingTheSameValueIsNotAChange() async throws {
        let model = try await model([0x41])

        model.type("4"); model.type("1")

        XCTAssertFalse(model.isChanged(at: 0), "the byte still matches the file, so it is not red")
    }

    func testRevertingPutsTheFileValueBack() async throws {
        let model = try await model([0x41, 0x42])
        model.type("F"); model.type("F")
        XCTAssertTrue(model.isChanged(at: 0))

        model.moveCursor(to: 0)
        model.revert()

        XCTAssertEqual(model.byte(at: 0), 0x41)
        XCTAssertFalse(model.hasEdits)
    }

    // MARK: - Selection

    func testShiftArrowsGrowARunFromTheAnchor() async throws {
        let model = try await model(Array(0 ..< 16))
        model.moveCursor(to: 4)

        model.moveCursor(by: 3, extending: true)

        XCTAssertEqual(model.selection, 4 ... 7)
        XCTAssertEqual(model.selectionCount, 4)
        XCTAssertTrue(model.hasSelection)
    }

    func testASelectionRunsBackwardsToo() async throws {
        let model = try await model(Array(0 ..< 16))
        model.moveCursor(to: 8)
        model.moveCursor(by: -3, extending: true)

        XCTAssertEqual(model.selection, 5 ... 8, "the anchor stays where it was")
        XCTAssertEqual(model.cursor, 5)
    }

    func testMovingWithoutShiftDropsTheSelection() async throws {
        let model = try await model(Array(0 ..< 16))
        model.moveCursor(to: 2)
        model.moveCursor(by: 4, extending: true)
        XCTAssertTrue(model.hasSelection)

        model.moveCursor(by: 1)

        XCTAssertFalse(model.hasSelection)
        XCTAssertEqual(model.selectionCount, 1)
    }

    func testSelectingStatesBothEndsAtOnce() async throws {
        // A drag says where it started and where it is now, so neither end
        // depends on a flag that could be left over from a previous gesture.
        let model = try await model(Array(0 ..< 16))

        model.select(from: 9, to: 3)

        XCTAssertEqual(model.selection, 3 ... 9, "either direction is the same run")
        XCTAssertEqual(model.cursor, 3, "and the cursor is the end that moved")
    }

    func testSelectingTheSameByteTwiceIsAPlainClick() async throws {
        let model = try await model(Array(0 ..< 16))
        model.select(from: 5, to: 5)

        XCTAssertFalse(model.hasSelection)
        XCTAssertEqual(model.cursor, 5)
    }

    func testSelectingIsClampedToTheFile() async throws {
        // What a click below the last row now resolves to, after an undo has
        // made the file shorter than the rows on screen.
        let model = try await model(Array(0 ..< 4))

        model.select(from: 99, to: 99)

        XCTAssertEqual(model.cursor, 3)
        XCTAssertEqual(model.anchor, 3)
    }

    func testRevertRestoresEveryChangedByteInTheSelection() async throws {
        let model = try await model([0x41, 0x42, 0x43, 0x44, 0x45])
        for offset in 1 ... 3 {
            model.moveCursor(to: offset)
            model.type("F"); model.type("F")
        }
        XCTAssertEqual(model.changedCount, 3)

        model.moveCursor(to: 1)
        model.moveCursor(to: 3, extending: true)
        model.revert()

        XCTAssertEqual((0 ..< 5).map { model.byte(at: $0) },
                       [0x41, 0x42, 0x43, 0x44, 0x45])
        XCTAssertFalse(model.hasEdits)
    }

    func testRevertLeavesChangesOutsideTheSelectionAlone() async throws {
        let model = try await model([0x41, 0x42, 0x43, 0x44])
        model.moveCursor(to: 0); model.type("F"); model.type("F")
        model.moveCursor(to: 3); model.type("E"); model.type("E")

        model.moveCursor(to: 3)
        model.revert()

        XCTAssertEqual(model.byte(at: 0), 0xFF, "the edit outside the selection stands")
        XCTAssertEqual(model.byte(at: 3), 0x44)
    }

    // MARK: - Structural editing

    func testRemovingPullsTheLaterBytesDown() async throws {
        let model = try await model([0, 1, 2, 3, 4, 5, 6, 7])
        model.moveCursor(to: 2)
        model.moveCursor(to: 4, extending: true)

        model.removeSelection()

        XCTAssertEqual(model.count, 5)
        XCTAssertEqual((0 ..< 5).map { model.byte(at: $0) }, [0, 1, 5, 6, 7])
        XCTAssertEqual(model.lengthDelta, -3)
        XCTAssertTrue(model.isStructural)
    }

    func testInsertingPushesTheLaterBytesUp() async throws {
        let model = try await model([1, 2, 3])
        model.moveCursor(to: 1)

        model.insertZeros(2)

        XCTAssertEqual(model.count, 5)
        XCTAssertEqual((0 ..< 5).map { model.byte(at: $0) }, [1, 0, 0, 2, 3])
        XCTAssertEqual(model.lengthDelta, 2)
    }

    func testInsertedBytesAreMarkedChangedAndMovedBytesAreNot() async throws {
        // A byte an insert merely pushed along is not a change: its value is
        // the one the file already had.
        let model = try await model([1, 2, 3])
        model.moveCursor(to: 1)

        model.insertZeros(2)

        XCTAssertTrue(model.isChanged(at: 1))
        XCTAssertTrue(model.isChanged(at: 2))
        XCTAssertFalse(model.isChanged(at: 3), "this byte only moved")
        XCTAssertEqual(model.changedCount, 2)
    }

    func testInsertingUsesTheSelectionSize() async throws {
        let model = try await model([1, 2, 3, 4])
        model.moveCursor(to: 1)
        model.moveCursor(to: 3, extending: true)

        model.insertZeros()

        XCTAssertEqual(model.count, 7, "three selected means three zeros")
    }

    func testAnEditSurvivesAnInsertThatMovesIt() async throws {
        // The pristine values are keyed by offset, so they have to move with
        // the bytes or Delete starts restoring the wrong ones.
        let model = try await model([0x41, 0x42, 0x43])
        model.moveCursor(to: 2)
        model.type("F"); model.type("F")
        XCTAssertTrue(model.isChanged(at: 2))

        model.moveCursor(to: 0)
        model.insertZeros(2)

        XCTAssertTrue(model.isChanged(at: 4), "the edited byte moved from 2 to 4")
        XCTAssertFalse(model.isChanged(at: 2), "and is no longer at 2")

        model.moveCursor(to: 4)
        model.revert()
        XCTAssertEqual(model.byte(at: 4), 0x43, "and Delete still restores it")
    }

    func testRemovingAnEditedByteForgetsItsPendingChange() async throws {
        let model = try await model([0x41, 0x42, 0x43])
        model.moveCursor(to: 1)
        model.type("F"); model.type("F")

        model.moveCursor(to: 1)
        model.removeSelection()

        XCTAssertEqual(model.count, 2)
        XCTAssertEqual((0 ..< 2).map { model.byte(at: $0) }, [0x41, 0x43])
        XCTAssertEqual(model.changedCount, 0, "the changed byte is gone, not still counted")
    }

    func testDiscardingAfterAStructuralEditRestoresTheLength() async throws {
        let model = try await model([1, 2, 3, 4])
        model.moveCursor(to: 0)
        model.insertZeros(4)
        XCTAssertEqual(model.count, 8)

        model.revertAll()

        XCTAssertEqual(model.count, 4)
        XCTAssertFalse(model.isStructural)
        XCTAssertFalse(model.hasEdits)
    }

    func testSavingAShorterFileTruncatesIt() async throws {
        let url = try makeFile(Array(0 ..< 10))
        let model = BinaryViewModel(url: url)
        while model.isLoading { await Task.yield() }
        model.moveCursor(to: 0)
        model.moveCursor(to: 3, extending: true)
        model.removeSelection()

        model.save()

        XCTAssertEqual([UInt8](try Data(contentsOf: url)), [4, 5, 6, 7, 8, 9])
        XCTAssertFalse(model.hasEdits, "and there is nothing left pending")
    }

    func testSavingALongerFileGrowsIt() async throws {
        let url = try makeFile([0xAA, 0xBB])
        let model = BinaryViewModel(url: url)
        while model.isLoading { await Task.yield() }
        model.moveCursor(to: 1)
        model.insertZeros(3)

        model.save()

        XCTAssertEqual([UInt8](try Data(contentsOf: url)), [0xAA, 0, 0, 0, 0xBB])
    }

    func testSavingAStructuralChangeKeepsTheFilesIdentity() async throws {
        // Written through the same descriptor rather than replaced, so the
        // inode and everything hanging off it survive.
        let url = try makeFile(Array(0 ..< 8))
        XCTAssertNil(ExtendedAttributes.set(Data("keep".utf8), name: "dev.diptych.test",
                                            on: url.path))
        let before = try fm.attributesOfItem(atPath: url.path)[.systemFileNumber] as? Int

        let model = BinaryViewModel(url: url)
        while model.isLoading { await Task.yield() }
        model.moveCursor(to: 0)
        model.insertZeros(2)
        model.save()

        let after = try fm.attributesOfItem(atPath: url.path)[.systemFileNumber] as? Int
        XCTAssertEqual(before, after, "the inode must not change")
        XCTAssertEqual(ExtendedAttributes.data(of: url.path, name: "dev.diptych.test"),
                       Data("keep".utf8), "nor may the extended attributes be lost")
    }

    func testSelectAllCoversTheWholeFile() async throws {
        let model = try await model(Array(0 ..< 6))
        model.selectAll()

        XCTAssertEqual(model.selection, 0 ... 5)
        XCTAssertEqual(model.selectionCount, 6)
    }

    // MARK: - Undo

    func testUndoTakesBackAnInsert() async throws {
        let model = try await model([1, 2, 3])
        model.moveCursor(to: 1)
        model.insertZeros(2)
        XCTAssertEqual(model.count, 5)

        model.undo()

        XCTAssertEqual(model.count, 3)
        XCTAssertEqual((0 ..< 3).map { model.byte(at: $0) }, [1, 2, 3])
        XCTAssertFalse(model.hasEdits)
    }

    func testUndoPutsRemovedBytesBackWhereTheyWere() async throws {
        let model = try await model([0, 1, 2, 3, 4])
        model.moveCursor(to: 1)
        model.moveCursor(to: 3, extending: true)
        model.removeSelection()
        XCTAssertEqual(model.count, 2)

        model.undo()

        XCTAssertEqual((0 ..< 5).map { model.byte(at: $0) }, [0, 1, 2, 3, 4])
        XCTAssertFalse(model.hasEdits)
    }

    func testUndoIsOnePerByteNotOnePerDigit() async throws {
        let model = try await model([0x41, 0x42])
        model.type("F"); model.type("F")
        XCTAssertEqual(model.byte(at: 0), 0xFF)

        model.undo()

        XCTAssertEqual(model.byte(at: 0), 0x41, "both digits go together")
        XCTAssertFalse(model.canUndo)
    }

    func testUndoUnwindsSeveralOperationsInOrder() async throws {
        let model = try await model([1, 2, 3])
        model.moveCursor(to: 0); model.type("F"); model.type("F")
        model.moveCursor(to: 0); model.insertZeros(1)
        XCTAssertEqual(model.count, 4)

        model.undo()
        XCTAssertEqual(model.count, 3)
        XCTAssertEqual(model.byte(at: 0), 0xFF, "the overwrite is still there")

        model.undo()
        XCTAssertEqual(model.byte(at: 0), 1)
        XCTAssertFalse(model.canUndo)
    }

    func testUndoBringsBackRevertedBytes() async throws {
        let model = try await model([0x41, 0x42, 0x43])
        model.moveCursor(to: 0); model.type("F"); model.type("F")
        model.moveCursor(to: 0)
        model.revert()
        XCTAssertEqual(model.byte(at: 0), 0x41)

        model.undo()

        XCTAssertEqual(model.byte(at: 0), 0xFF, "reverting is itself undoable")
        XCTAssertTrue(model.isChanged(at: 0))
    }

    func testUndoAfterAnInsertRestoresWhichBytesAreMarkedNew() async throws {
        // The record of which bytes are new is keyed by offset, so it has to be
        // put back with the content or the colours end up on the wrong bytes.
        let model = try await model([1, 2, 3])
        model.moveCursor(to: 0); model.insertZeros(2)
        model.moveCursor(to: 0); model.insertZeros(1)

        model.undo()

        XCTAssertTrue(model.isChanged(at: 0))
        XCTAssertTrue(model.isChanged(at: 1))
        XCTAssertFalse(model.isChanged(at: 2), "this one only ever moved")
        XCTAssertEqual(model.changedCount, 2)
    }

    func testSavingClearsTheUndoStack() async throws {
        // The reversals describe edits against content that is now on disk.
        let url = try makeFile([1, 2, 3])
        let model = BinaryViewModel(url: url)
        while model.isLoading { await Task.yield() }
        model.type("F"); model.type("F")
        XCTAssertTrue(model.canUndo)

        model.save()

        XCTAssertFalse(model.canUndo)
    }

    func testUndoOnAnUntouchedFileDoesNothing() async throws {
        let model = try await model([1, 2, 3])
        model.undo()
        XCTAssertEqual((0 ..< 3).map { model.byte(at: $0) }, [1, 2, 3])
    }

    // MARK: - Finding

    func testFindingText() async throws {
        let model = try await model(Array("xxHello worldxx".utf8))
        model.findQuery = "Hello"

        model.findNext()

        XCTAssertEqual(model.selection, 2 ... 6, "the whole match is selected")
        XCTAssertEqual(model.cursor, 6)
    }

    func testFindingHexWithOrWithoutSpaces() async throws {
        let model = try await model([0x00, 0xDE, 0xAD, 0xBE, 0xEF])
        model.findIsHex = true

        model.findQuery = "DEADBEEF"
        XCTAssertEqual(model.findPattern, [0xDE, 0xAD, 0xBE, 0xEF])
        model.findQuery = "de ad be ef"
        XCTAssertEqual(model.findPattern, [0xDE, 0xAD, 0xBE, 0xEF])

        model.findNext()
        XCTAssertEqual(model.selection, 1 ... 4)
    }

    func testHalfATypedHexPairIsNotAPattern() async throws {
        let model = try await model([0xAB])
        model.findIsHex = true
        model.findQuery = "AB C"

        XCTAssertNil(model.findPattern, "an odd number of digits is not bytes")
    }

    func testTextAndHexReadTheSameQueryDifferently() async throws {
        // "41" is the two characters 4 and 1 as text, and the single byte 0x41
        // as hex. Getting these the same way round is the whole point.
        let model = try await model(Array("A41".utf8))

        model.findQuery = "41"
        XCTAssertEqual(model.findPattern, Array("41".utf8))
        model.findNext()
        XCTAssertEqual(model.selection.lowerBound, 1)

        model.findIsHex = true
        XCTAssertEqual(model.findPattern, [0x41])
        model.moveCursor(to: 0)
        model.findNext()
        XCTAssertEqual(model.selection, 0 ... 0, "0x41 is the 'A'")
    }

    func testFindingAgainWalksOnAndWraps() async throws {
        let model = try await model(Array("ababab".utf8))
        model.findQuery = "ab"

        model.findNext()
        XCTAssertEqual(model.selection.lowerBound, 0)
        model.findNext()
        XCTAssertEqual(model.selection.lowerBound, 2)
        model.findNext()
        XCTAssertEqual(model.selection.lowerBound, 4)
        model.findNext()
        XCTAssertEqual(model.selection.lowerBound, 0, "and round again")
    }

    func testFindingBackwards() async throws {
        let model = try await model(Array("ab..ab".utf8))
        model.findQuery = "ab"
        model.moveCursor(to: 5)

        model.findPrevious()

        XCTAssertEqual(model.selection.lowerBound, 4)
        model.findPrevious()
        XCTAssertEqual(model.selection.lowerBound, 0)
    }

    func testFindingWhatIsNotThereLeavesTheSelectionAlone() async throws {
        let model = try await model(Array("abc".utf8))
        model.moveCursor(to: 1)
        model.findQuery = "zzz"

        model.findNext()

        XCTAssertEqual(model.cursor, 1)
        XCTAssertTrue(model.statusIsError)
    }

    func testFindingSeesPendingEdits() async throws {
        // What is searched is what is shown, not what is on disk.
        let model = try await model(Array("aXc".utf8))
        model.moveCursor(to: 1)
        model.type("6"); model.type("2")            // 0x62 is "b"

        model.moveCursor(to: 0)
        model.findQuery = "abc"
        model.findNext()

        XCTAssertEqual(model.selection, 0 ... 2)
    }

    func testFindingAPatternLongerThanTheFile() async throws {
        let model = try await model([1, 2])
        model.findQuery = "abcdef"

        model.findNext()

        XCTAssertTrue(model.statusIsError, "and no crash on the empty range")
    }

    // MARK: - Writing

    func testOnlyTheChangedBytesAreWritten() async throws {
        let url = try makeFile(Array(repeating: 0xAA, count: 16))
        let model = BinaryViewModel(url: url)
        while model.isLoading { await Task.yield() }
        model.moveCursor(to: 4)
        model.type("0"); model.type("1")
        model.moveCursor(to: 9)
        model.type("0"); model.type("2")

        model.save()

        var expected = [UInt8](repeating: 0xAA, count: 16)
        expected[4] = 1
        expected[9] = 2
        XCTAssertEqual([UInt8](try Data(contentsOf: url)), expected)
        XCTAssertFalse(model.hasEdits, "saving clears the pending changes")
    }

    func testWritingDoesNotChangeTheFileLength() async throws {
        let url = try makeFile(Array(0 ..< 32))
        let model = BinaryViewModel(url: url)
        while model.isLoading { await Task.yield() }
        model.moveCursor(to: 31)
        model.type("F"); model.type("F")

        model.save()

        XCTAssertEqual(try Data(contentsOf: url).count, 32, "a patch must not truncate")
    }

    func testAdjacentChangesBecomeOneRun() async throws {
        // Contiguous edits are written with one seek, which is both faster and
        // the thing that makes a multi-byte change atomic in practice.
        let model = try await model(Array(repeating: 0, count: 8))
        for _ in 0 ..< 3 { model.type("F"); model.type("F") }

        let runs = model.runs
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs.first?.offset, 0)
        XCTAssertEqual(runs.first?.bytes, [0xFF, 0xFF, 0xFF])
    }

    func testSeparatedChangesStaySeparateRuns() async throws {
        let model = try await model(Array(repeating: 0, count: 8))
        model.moveCursor(to: 1); model.type("1"); model.type("1")
        model.moveCursor(to: 5); model.type("2"); model.type("2")

        XCTAssertEqual(model.runs.map(\.offset), [1, 5])
    }

    func testAnEmptyFileIsNotAnError() async throws {
        let model = try await model([])

        XCTAssertNil(model.loadError)
        XCTAssertEqual(model.rowCount, 0)
        model.type("F")
        XCTAssertFalse(model.hasEdits, "there is no byte to edit")
    }

    func testTheCursorCannotLeaveTheFile() async throws {
        let model = try await model(Array(0 ..< 4))

        model.moveCursor(by: -10)
        XCTAssertEqual(model.cursor, 0)
        model.moveCursor(by: 100)
        XCTAssertEqual(model.cursor, 3)
    }
}
