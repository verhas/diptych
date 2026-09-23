import XCTest
@testable import Diptych

/// Comparing two files byte by byte, and what it says about them.
final class BinaryComparisonTests: XCTestCase {

    private var folder: URL!
    private let manager = FileManager.default

    override func setUpWithError() throws {
        folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("DiptychBytes-\(UUID().uuidString)")
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? manager.removeItem(at: folder)
    }

    private func file(_ name: String, _ bytes: [UInt8]) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data(bytes).write(to: url)
        return url
    }

    private func file(_ name: String, _ data: Data) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    // MARK: - The three answers

    func testTwoFilesWithTheSameBytesAreTheSame() throws {
        let left = try file("a.bin", [0, 1, 2, 3, 0xFF])
        let right = try file("b.bin", [0, 1, 2, 3, 0xFF])

        let comparison = try BinaryComparison.compare(left, right)

        XCTAssertTrue(comparison.isIdentical)
        XCTAssertNil(comparison.firstDifference)
        XCTAssertEqual(comparison.commonPrefix, 5)
        let verdict = comparison.verdict(left: "a.bin", right: "b.bin")
        XCTAssertTrue(verdict.contains("exactly the same"), verdict)
        XCTAssertTrue(verdict.contains("5 bytes"), verdict)
    }

    func testFilesThatDifferFromTheFirstByteSaySo() throws {
        let left = try file("a.bin", [1, 2, 3])
        let right = try file("b.bin", [9, 2, 3])

        let comparison = try BinaryComparison.compare(left, right)

        XCTAssertFalse(comparison.isIdentical)
        XCTAssertEqual(comparison.firstDifference, 0)
        XCTAssertEqual(comparison.commonPrefix, 0)
        let verdict = comparison.verdict(left: "a.bin", right: "b.bin")
        XCTAssertTrue(verdict.contains("from the very first byte"), verdict)
    }

    func testFilesThatShareABeginningSayHowMuch() throws {
        let left = try file("a.bin", [1, 2, 3, 4, 5])
        let right = try file("b.bin", [1, 2, 3, 9, 5])

        let comparison = try BinaryComparison.compare(left, right)

        XCTAssertEqual(comparison.firstDifference, 3)
        XCTAssertEqual(comparison.commonPrefix, 3)
        let verdict = comparison.verdict(left: "a.bin", right: "b.bin")
        XCTAssertTrue(verdict.contains("first 3 bytes are identical"), verdict)
        XCTAssertFalse(comparison.oneIsTheStartOfTheOther, "they contradict at byte 4")
        XCTAssertTrue(verdict.contains("byte 4"), "counted from one, for a reader: \(verdict)")
        XCTAssertTrue(verdict.contains("0x3"), verdict)
    }

    // MARK: - One is the start of the other

    func testAFileThatIsTheBeginningOfTheOtherIsSaidToBe() throws {
        let left = try file("short.bin", [1, 2, 3])
        let right = try file("long.bin", [1, 2, 3, 4, 5, 6])

        let comparison = try BinaryComparison.compare(left, right)

        XCTAssertFalse(comparison.isIdentical)
        XCTAssertNil(comparison.firstDifference, "nothing contradicts")
        XCTAssertTrue(comparison.oneIsTheStartOfTheOther)
        XCTAssertEqual(comparison.commonPrefix, 3)
        let verdict = comparison.verdict(left: "short.bin", right: "long.bin")
        XCTAssertTrue(verdict.contains("\u{201C}short.bin\u{201D} is exactly the first"), verdict)
        XCTAssertTrue(verdict.contains("3 bytes more") || verdict.contains("3 bytes"), verdict)
    }

    func testTheLongerOneMayBeTheLeft() throws {
        let left = try file("long.bin", [7, 7, 7, 7])
        let right = try file("short.bin", [7, 7])

        let comparison = try BinaryComparison.compare(left, right)

        XCTAssertTrue(comparison.oneIsTheStartOfTheOther)
        let verdict = comparison.verdict(left: "long.bin", right: "short.bin")
        XCTAssertTrue(verdict.contains("\u{201C}short.bin\u{201D} is exactly the first"), verdict)
    }

    // MARK: - Nothing in them

    func testTwoEmptyFilesAreTheSame() throws {
        let left = try file("a.bin", [])
        let right = try file("b.bin", [])

        let comparison = try BinaryComparison.compare(left, right)

        XCTAssertTrue(comparison.isIdentical)
        XCTAssertEqual(comparison.verdict(left: "a.bin", right: "b.bin"),
                       "Both files are empty.")
    }

    func testAnEmptyFileAgainstOneWithSomethingInIt() throws {
        let left = try file("empty.bin", [])
        let right = try file("full.bin", [1, 2, 3])

        let comparison = try BinaryComparison.compare(left, right)

        XCTAssertFalse(comparison.isIdentical)
        let verdict = comparison.verdict(left: "empty.bin", right: "full.bin")
        XCTAssertTrue(verdict.contains("\u{201C}empty.bin\u{201D} is empty"), verdict)
    }

    // MARK: - Bigger than one read

    func testADifferenceBeyondTheFirstChunkIsFound() throws {
        // The comparison reads a megabyte at a time; a difference just past
        // that boundary is where an off-by-one hides.
        let size = BinaryComparison.chunk + 10
        var bytes = Data(repeating: 0xAB, count: size)
        var other = bytes
        other[BinaryComparison.chunk + 3] = 0xCD
        let left = try file("a.bin", bytes)
        let right = try file("b.bin", other)

        let comparison = try BinaryComparison.compare(left, right)

        XCTAssertEqual(comparison.firstDifference, Int64(BinaryComparison.chunk + 3))
        bytes[0] = 0xAB   // silence the unused-mutation warning
    }

    func testTwoLargeIdenticalFilesAreTheSame() throws {
        let data = Data((0 ..< (BinaryComparison.chunk * 2 + 7)).map { UInt8($0 % 251) })
        let left = try file("a.bin", data)
        let right = try file("b.bin", data)

        let comparison = try BinaryComparison.compare(left, right)

        XCTAssertTrue(comparison.isIdentical)
        XCTAssertEqual(comparison.commonPrefix, Int64(data.count))
    }

    func testALongPrefixIsReportedInBothRoundAndExactBytes() throws {
        let shared = Data(repeating: 0x5A, count: 4096)
        let left = try file("a.bin", shared + Data([1]))
        let right = try file("b.bin", shared + Data([2]))

        let comparison = try BinaryComparison.compare(left, right)

        XCTAssertEqual(comparison.commonPrefix, 4096)
        let verdict = comparison.verdict(left: "a.bin", right: "b.bin")
        // Grouped the way this Mac groups numbers, whatever that is.
        XCTAssertTrue(verdict.contains("\(Int64(4096).formatted(.number)) bytes"),
                      "the exact count is there: \(verdict)")
        XCTAssertTrue(verdict.contains("KB"), "and the round one: \(verdict)")
    }

    // MARK: - What cannot be read

    func testAMissingFileIsAnError() throws {
        let left = try file("a.bin", [1])
        let missing = folder.appendingPathComponent("not-here.bin")

        XCTAssertThrowsError(try BinaryComparison.compare(left, missing))
    }
}
