import XCTest
@testable import Diptych

/// The alignment is the part worth testing. The diff itself is the standard
/// library's; what is written here is the rebuilding of two columns that line
/// up on screen, and that is where the mistakes live.
final class TextDiffTests: XCTestCase {

    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("DiptychDiff-\(UUID().uuidString)")
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

    // MARK: - Alignment

    func testIdenticalFilesHaveNothingToShow() {
        let diff = TextDiff(left: ["one", "two"], right: ["one", "two"])

        XCTAssertTrue(diff.isIdentical)
        XCTAssertEqual(diff.rows.count, 2)
        XCTAssertTrue(diff.rows.allSatisfy { $0.kind == .same })
    }

    func testARewrittenLineIsOneRowNotTwo() {
        // A removal and an insertion in the same place is one line rewritten.
        // Shown as a deletion followed by an addition it reads as two separate
        // events, which is not what happened.
        let diff = TextDiff(left: ["one", "two", "three"],
                            right: ["one", "TWO", "three"])

        XCTAssertEqual(diff.rows.count, 3)
        XCTAssertEqual(diff.rows[1].kind, .changed)
        XCTAssertEqual(diff.rows[1].left, "two")
        XCTAssertEqual(diff.rows[1].right, "TWO")
        XCTAssertEqual(diff.changeStarts, [1])
    }

    func testAnAddedLineLeavesAGapOnTheOtherSide() {
        let diff = TextDiff(left: ["one", "three"],
                            right: ["one", "two", "three"])

        XCTAssertEqual(diff.rows.map(\.kind), [.same, .added, .same])
        XCTAssertNil(diff.rows[1].left, "nothing on the left, so the columns stay level")
        XCTAssertEqual(diff.rows[1].right, "two")
        XCTAssertNil(diff.rows[1].leftNumber, "and no line number invented for it")
    }

    func testARemovedLineLeavesAGapToo() {
        let diff = TextDiff(left: ["one", "two", "three"],
                            right: ["one", "three"])

        XCTAssertEqual(diff.rows.map(\.kind), [.same, .removed, .same])
        XCTAssertEqual(diff.rows[1].left, "two")
        XCTAssertNil(diff.rows[1].right)
    }

    func testLineNumbersCountEachSideSeparately() {
        // The whole reason both numbers are kept: after one insertion the two
        // files disagree about what line anything is on.
        let diff = TextDiff(left: ["a", "b"],
                            right: ["a", "new", "b"])

        XCTAssertEqual(diff.rows.map(\.leftNumber), [1, nil, 2])
        XCTAssertEqual(diff.rows.map(\.rightNumber), [1, 2, 3])
    }

    func testARunOfChangedLinesCountsAsOneDifference() {
        // Someone reading wants the next *difference*, not the next line of the
        // one they are already looking at.
        let diff = TextDiff(left: ["a", "b", "c", "d", "e"],
                            right: ["a", "B", "C", "d", "E"])

        XCTAssertEqual(diff.changeStarts, [1, 4], "one run, then another")
    }

    func testEverythingReplaced() {
        let diff = TextDiff(left: ["a", "b"], right: ["x", "y"])

        XCTAssertFalse(diff.isIdentical)
        XCTAssertTrue(diff.rows.allSatisfy { $0.kind.isChange })
        XCTAssertEqual(diff.rows.compactMap(\.left), ["a", "b"], "every line accounted for")
        XCTAssertEqual(diff.rows.compactMap(\.right), ["x", "y"])
    }

    func testAnEmptyFileAgainstAFullOne() {
        let diff = TextDiff(left: [], right: ["one", "two"])

        XCTAssertEqual(diff.rows.map(\.kind), [.added, .added])
        XCTAssertEqual(diff.changeStarts, [0])
    }

    func testTwoEmptyFilesAreTheSame() {
        XCTAssertTrue(TextDiff(left: [], right: []).isIdentical)
    }

    func testEveryLineOfBothFilesAppearsSomewhere() {
        // The alignment walk is the kind of loop that silently drops a line at
        // the end, and a diff that loses a line is worse than no diff at all.
        let left = (1...40).map { "left \($0 % 7)" }
        let right = (1...50).map { "right \($0 % 5)" }

        let diff = TextDiff(left: left, right: right)

        XCTAssertEqual(diff.rows.compactMap(\.left), left)
        XCTAssertEqual(diff.rows.compactMap(\.right), right)
    }

    // MARK: - Reading files

    func testATrailingNewlineDoesNotAddAnEmptyLine() throws {
        let url = try write("a.txt", "one\ntwo\n")

        XCTAssertEqual(try TextDiff.read(url), ["one", "two"])
    }

    func testAFileWithoutATrailingNewlineReadsTheSame() throws {
        let url = try write("b.txt", "one\ntwo")

        XCTAssertEqual(try TextDiff.read(url), ["one", "two"])
    }

    func testABinaryFileIsRefusedRatherThanShownAsRubbish() throws {
        let url = root.appendingPathComponent("thing.bin")
        try Data([0x7f, 0x45, 0x4c, 0x46, 0x00, 0x01, 0x02, 0x00]).write(to: url)

        XCTAssertThrowsError(try TextDiff.read(url)) { error in
            guard case TextDiff.Failure.notText(let name) = error else {
                return XCTFail("\(error)")
            }
            XCTAssertEqual(name, "thing.bin")
        }
    }

    func testAFileWrittenOnWindowsIsNotDoubleSpaced() throws {
        // `.newlines` counts CR and LF separately, so every real line came back
        // followed by a phantom blank one and the whole comparison was rubbish.
        let url = root.appendingPathComponent("crlf.txt")
        try Data("one\r\ntwo\r\nthree\r\n".utf8).write(to: url)

        XCTAssertEqual(try TextDiff.read(url), ["one", "two", "three"])
    }

    func testOldMacLineEndingsWorkToo() throws {
        let url = root.appendingPathComponent("cr.txt")
        try Data("one\rtwo\r".utf8).write(to: url)

        XCTAssertEqual(try TextDiff.read(url), ["one", "two"])
    }

    func testBlankLinesInTheMiddleAreKept() {
        // A paragraph break is a line, and losing it would misalign everything
        // after it.
        XCTAssertEqual(TextDiff.lines(of: "one\n\ntwo\n"), ["one", "", "two"])
    }

    func testTheSameFileWithTwoLineEndingsComparesAsEqual() throws {
        let unix = root.appendingPathComponent("u.txt")
        let windows = root.appendingPathComponent("w.txt")
        try Data("alpha\nbeta\n".utf8).write(to: unix)
        try Data("alpha\r\nbeta\r\n".utf8).write(to: windows)

        XCTAssertTrue(try TextDiff.compare(unix, windows).isIdentical,
                      "the text is the same; only the invisible bytes differ")
    }

    func testTextWithAccentsSurvives() throws {
        let url = try write("c.txt", "Grüße\nZürich\n")

        XCTAssertEqual(try TextDiff.read(url), ["Grüße", "Zürich"])
    }

    func testComparingTwoRealFiles() throws {
        let left = try write("left.md", "# Title\n\nfirst\nsecond\n")
        let right = try write("right.md", "# Title\n\nfirst\nSECOND\nthird\n")

        let diff = try TextDiff.compare(left, right)

        XCTAssertEqual(diff.rows.map(\.kind), [.same, .same, .same, .changed, .added])
        XCTAssertEqual(diff.changeStarts, [3], "the two touching changes read as one")
    }

    // MARK: - Within one line

    func testOnlyTheWordThatChangedIsMarked() {
        // The point of the whole thing: in a long line, seeing *what* changed
        // rather than that something did.
        let marked = TextDiff.spans(left: "The quick brown fox jumps over the lazy dog",
                                    right: "The quick brown cat jumps over the lazy dog")

        XCTAssertEqual(marked?.left.filter(\.changed).map(\.text), ["fox"])
        XCTAssertEqual(marked?.right.filter(\.changed).map(\.text), ["cat"])
    }

    func testTheWholeLineIsStillThereAfterMarking() {
        // Spans are the line cut up, so losing a character here would lose it
        // on screen.
        let line = "one, two; three  four"
        let marked = TextDiff.spans(left: line, right: "one, two; THREE  four")

        XCTAssertEqual(marked?.left.map(\.text).joined(), line)
    }

    func testNeighbouringChangedWordsBecomeOneBlock() {
        // Otherwise a changed phrase is drawn as a row of separate patches.
        let marked = TextDiff.spans(left: "keep the old words here",
                                    right: "keep the new better words here")

        let changed = marked?.right.filter(\.changed).map(\.text) ?? []
        XCTAssertEqual(changed.count, 1, "one block, not three: \(changed)")
    }

    func testTwoQuiteDifferentLinesAreNotMarkedAtAll() {
        // Marking a rewritten line entirely is the same as not marking it, with
        // extra noise on top.
        //
        // This one caught a real mistake: similarity was counted over every
        // token, and two sentences with nothing whatever in common still share
        // all their spaces -- which made these two look 43% alike.
        XCTAssertNil(TextDiff.spans(left: "the quick brown fox",
                                    right: "entirely unrelated content indeed"))
        XCTAssertNil(TextDiff.spans(left: "a b c d e f g h",
                                    right: "q w e r t y u i"),
                     "shared spaces are not shared meaning")
    }

    func testAVeryLongLineIsLeftAlone() {
        let long = String(repeating: "word ", count: 1000)

        XCTAssertNil(TextDiff.spans(left: long, right: long + "tail"))
    }

    func testPunctuationIsItsOwnToken() {
        // So changing a comma marks the comma, not the words either side of it.
        XCTAssertEqual(TextDiff.tokens(of: "one,two"), ["one", ",", "two"])
        XCTAssertEqual(TextDiff.tokens(of: "a  b"), ["a", "  ", "b"])
    }

    func testARewrittenLineCarriesItsMarkingIntoTheRow() {
        let diff = TextDiff(left: ["title", "the value is 41", "end"],
                            right: ["title", "the value is 42", "end"])

        XCTAssertEqual(diff.rows[1].kind, .changed)
        XCTAssertEqual(diff.rows[1].leftSpans.filter(\.changed).map(\.text), ["41"])
        XCTAssertEqual(diff.rows[1].rightSpans.filter(\.changed).map(\.text), ["42"])
    }

    func testAnAddedLineHasNothingToMark() {
        let diff = TextDiff(left: ["one"], right: ["one", "two"])

        XCTAssertTrue(diff.rows[1].rightSpans.isEmpty, "nothing to compare it against")
    }

    // MARK: - Which file is which

    func testFilesInOneFolderNeedNoFolderShown() {
        let pair = DiffPair(left: URL(fileURLWithPath: "/work/notes/a.md"),
                            right: URL(fileURLWithPath: "/work/notes/b.md"))

        XCTAssertNil(pair.folders, "the names already tell them apart")
    }

    func testTheSameNameInTwoFoldersShowsWhatDiffers() {
        // Reported: two files of the same name looked identical in the header,
        // and the whole window was ambiguous.
        let pair = DiffPair(left: URL(fileURLWithPath: "/work/project/p1/notes.md"),
                            right: URL(fileURLWithPath: "/work/project/p2/notes.md"))

        let folders = pair.folders
        XCTAssertEqual(folders?.left, "\u{2026}/p1")
        XCTAssertEqual(folders?.right, "\u{2026}/p2")
    }

    func testFoldersWithNothingInCommonAreShownWhole() {
        let pair = DiffPair(left: URL(fileURLWithPath: "/work/notes.md"),
                            right: URL(fileURLWithPath: "/tmp/notes.md"))

        XCTAssertEqual(pair.folders?.left, "/work")
        XCTAssertEqual(pair.folders?.right, "/tmp")
    }

    func testOneFolderInsideTheOtherIsShownWhole() {
        // Trimming what they share would leave one side with nothing at all.
        let pair = DiffPair(left: URL(fileURLWithPath: "/work/notes.md"),
                            right: URL(fileURLWithPath: "/work/old/notes.md"))

        XCTAssertEqual(pair.folders?.left, "/work")
        XCTAssertEqual(pair.folders?.right, "/work/old")
    }
}
