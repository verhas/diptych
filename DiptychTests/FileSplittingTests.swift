import XCTest
@testable import Diptych

/// Split File… and Join Parts: cutting a file into numbered parts and putting
/// them back together, byte for byte.
final class FileSplittingTests: XCTestCase {

    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("DiptychSplit-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    @discardableResult
    private func write(_ name: String, _ bytes: Data) throws -> URL {
        let url = root.appendingPathComponent(name)
        try bytes.write(to: url)
        return url
    }

    private func bytes(_ count: Int) -> Data {
        Data((0 ..< count).map { UInt8($0 & 0xff) })
    }

    // MARK: - Splitting

    func testSplitMakesNumberedPartsOfTheRightSizes() throws {
        // 250 bytes in 100-byte parts: 100, 100, 50.
        let file = try write("blob.bin", bytes(250))
        let parts = try FileSplitting.split(file, partSize: 100, into: nil)
        XCTAssertEqual(parts.map(\.lastPathComponent),
                       ["blob.bin.001", "blob.bin.002", "blob.bin.003"])
        XCTAssertEqual(try parts.map { try Data(contentsOf: $0).count }, [100, 100, 50])
    }

    func testPartNamesGetEnoughDigitsForManyParts() throws {
        // 1500 bytes in 1-byte parts needs four digits (0001 … 1500).
        let file = try write("many.bin", bytes(1500))
        let parts = try FileSplitting.split(file, partSize: 1, into: nil)
        XCTAssertEqual(parts.count, 1500)
        XCTAssertEqual(parts.first?.lastPathComponent, "many.bin.0001")
        XCTAssertEqual(parts.last?.lastPathComponent, "many.bin.1500")
    }

    func testSplittingAnEmptyFileThrows() throws {
        let file = try write("empty.bin", Data())
        XCTAssertThrowsError(try FileSplitting.split(file, partSize: 100, into: nil))
    }

    func testSplitCanWritePartsIntoAnotherFolder() throws {
        let file = try write("payload.bin", bytes(300))
        let other = root.appendingPathComponent("parts")
        try fm.createDirectory(at: other, withIntermediateDirectories: true)
        let parts = try FileSplitting.split(file, partSize: 128, into: other)
        XCTAssertEqual(parts.first?.deletingLastPathComponent().standardizedFileURL.path,
                       other.standardizedFileURL.path)
        XCTAssertEqual(parts.count, 3)
    }

    // MARK: - Recognising a first part

    func testIsFirstPartAcceptsOnlyAProperFirstPartName() {
        XCTAssertTrue(FileSplitting.isFirstPart(root.appendingPathComponent("a.zip.001")))
        XCTAssertTrue(FileSplitting.isFirstPart(root.appendingPathComponent("a.zip.0001")))
        XCTAssertFalse(FileSplitting.isFirstPart(root.appendingPathComponent("a.zip.002")))
        XCTAssertFalse(FileSplitting.isFirstPart(root.appendingPathComponent("a.zip.01")))  // too short
        XCTAssertFalse(FileSplitting.isFirstPart(root.appendingPathComponent("a.zip")))
    }

    // MARK: - Round trip

    func testSplitThenJoinReproducesTheFileByteForByte() throws {
        let original = bytes(1000)
        let file = try write("round.bin", original)
        let parts = try FileSplitting.split(file, partSize: 256, into: nil)
        XCTAssertEqual(parts.count, 4)

        // The original is removed, so the join has only the parts to work from
        // and cannot be accidentally reading it.
        try fm.removeItem(at: file)

        let joined = try FileSplitting.join(firstPart: parts[0], into: nil)
        XCTAssertEqual(joined.lastPathComponent, "round.bin")
        XCTAssertEqual(try Data(contentsOf: joined), original)
    }

    func testJoinStepsPastANameAlreadyTaken() throws {
        let file = try write("keep.bin", bytes(200))
        let parts = try FileSplitting.split(file, partSize: 100, into: nil)
        // The original is still there, so the join must not overwrite it.
        let joined = try FileSplitting.join(firstPart: parts[0], into: nil)
        XCTAssertEqual(joined.lastPathComponent, "keep (2).bin")
        XCTAssertEqual(try Data(contentsOf: file), bytes(200))        // untouched
        XCTAssertEqual(try Data(contentsOf: joined), bytes(200))
    }

    func testJoiningStopsAtTheFirstMissingPart() throws {
        let file = try write("gap.bin", bytes(300))
        let parts = try FileSplitting.split(file, partSize: 100, into: nil)
        XCTAssertEqual(parts.count, 3)
        // Remove the middle part: only the first is reachable without a gap.
        try fm.removeItem(at: parts[1])
        XCTAssertEqual(FileSplitting.parts(firstPart: parts[0]).count, 1)
    }

    func testJoiningSomethingThatIsNotAFirstPartThrows() throws {
        let notAPart = try write("whole.bin", bytes(10))
        XCTAssertThrowsError(try FileSplitting.join(firstPart: notAPart, into: nil))
    }
}
