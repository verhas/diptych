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
}
