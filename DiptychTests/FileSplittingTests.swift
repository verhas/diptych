import XCTest
@testable import Diptych

/// Split File… and Join Parts: cutting a file into numbered parts and putting
/// them back together, byte for byte -- with a manifest that notices a part
/// gone missing or corrupted.
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
        let parts = try FileSplitting.split(file, partSize: 100, into: nil).parts
        XCTAssertEqual(parts.map(\.lastPathComponent),
                       ["blob.bin.001", "blob.bin.002", "blob.bin.003"])
        XCTAssertEqual(try parts.map { try Data(contentsOf: $0).count }, [100, 100, 50])
    }

    func testPartNamesGetEnoughDigitsForManyParts() throws {
        // 1500 bytes in 1-byte parts needs four digits (0001 … 1500).
        let file = try write("many.bin", bytes(1500))
        let parts = try FileSplitting.split(file, partSize: 1, into: nil).parts
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
        let parts = try FileSplitting.split(file, partSize: 128, into: other).parts
        XCTAssertEqual(parts.first?.deletingLastPathComponent().standardizedFileURL.path,
                       other.standardizedFileURL.path)
        XCTAssertEqual(parts.count, 3)
    }

    func testPartCountCountsWhatASplitWouldMake() {
        XCTAssertEqual(FileSplitting.partCount(totalSize: 250, partSize: 100), 3)
        XCTAssertEqual(FileSplitting.partCount(totalSize: 200, partSize: 100), 2)
        XCTAssertEqual(FileSplitting.partCount(totalSize: 1, partSize: 100), 1)
        XCTAssertEqual(FileSplitting.partCount(totalSize: 0, partSize: 100), 0)
    }

    // MARK: - The manifest

    func testSplitWritesAManifestBesideTheParts() throws {
        let file = try write("doc.dat", bytes(500))
        let output = try FileSplitting.split(file, partSize: 200, into: nil)
        XCTAssertEqual(output.manifest.lastPathComponent, "doc.dat.diptychsplit.json")
        XCTAssertTrue(fm.fileExists(atPath: output.manifest.path))

        let manifest = try JSONDecoder().decode(FileSplitting.Manifest.self,
                                                from: Data(contentsOf: output.manifest))
        XCTAssertEqual(manifest.file, "doc.dat")
        XCTAssertEqual(manifest.totalSize, 500)
        XCTAssertEqual(manifest.parts.count, 3)
        XCTAssertEqual(manifest.parts.map(\.size), [200, 200, 100])
        // Each recorded sum matches the part on disk.
        for part in manifest.parts {
            let url = root.appendingPathComponent(part.name)
            XCTAssertEqual(Checksums.digest(of: url, algorithm: .sha512), part.sha512)
        }
    }

    // MARK: - Recognising parts

    func testIsFirstPartAcceptsOnlyAProperFirstPartName() {
        XCTAssertTrue(FileSplitting.isFirstPart(root.appendingPathComponent("a.zip.001")))
        XCTAssertTrue(FileSplitting.isFirstPart(root.appendingPathComponent("a.zip.0001")))
        XCTAssertFalse(FileSplitting.isFirstPart(root.appendingPathComponent("a.zip.002")))
        XCTAssertFalse(FileSplitting.isFirstPart(root.appendingPathComponent("a.zip.01")))  // too short
        XCTAssertFalse(FileSplitting.isFirstPart(root.appendingPathComponent("a.zip")))
    }

    func testIsPartAcceptsAnyPartNumber() {
        XCTAssertTrue(FileSplitting.isPart(root.appendingPathComponent("a.zip.007")))
        XCTAssertTrue(FileSplitting.isPart(root.appendingPathComponent("a.zip.0150")))
        XCTAssertFalse(FileSplitting.isPart(root.appendingPathComponent("a.zip.07")))
        XCTAssertFalse(FileSplitting.isPart(root.appendingPathComponent("a.zip")))
    }

    func testJoinSourceResolvesAnySelectionToAStartingPoint() {
        let one = root.appendingPathComponent("a.zip.007")
        let two = root.appendingPathComponent("a.zip.008")
        let other = root.appendingPathComponent("b.zip.001")
        let manifest = root.appendingPathComponent("a.zip.diptychsplit.json")

        // A single later part → the first part of its set.
        XCTAssertEqual(FileSplitting.joinSource(for: [one])?.lastPathComponent, "a.zip.001")
        // Several parts of one file → the first part.
        XCTAssertEqual(FileSplitting.joinSource(for: [two, one])?.lastPathComponent, "a.zip.001")
        // The manifest stands for itself.
        XCTAssertEqual(FileSplitting.joinSource(for: [manifest])?.lastPathComponent,
                       "a.zip.diptychsplit.json")
        // Parts of different files, or a non-part, are not a join.
        XCTAssertNil(FileSplitting.joinSource(for: [one, other]))
        XCTAssertNil(FileSplitting.joinSource(for: [root.appendingPathComponent("plain.txt")]))
        XCTAssertNil(FileSplitting.joinSource(for: []))
    }

    // MARK: - Round trip

    func testSplitThenJoinReproducesTheFileByteForByte() throws {
        let original = bytes(1000)
        let file = try write("round.bin", original)
        let parts = try FileSplitting.split(file, partSize: 256, into: nil).parts
        XCTAssertEqual(parts.count, 4)

        // The original is removed, so the join has only the parts to work from
        // and cannot be accidentally reading it.
        try fm.removeItem(at: file)

        let joined = try FileSplitting.join(from: parts[0], into: nil)
        XCTAssertEqual(joined.lastPathComponent, "round.bin")
        XCTAssertEqual(try Data(contentsOf: joined), original)
    }

    func testJoinWorksFromAnyPartOrTheManifest() throws {
        let original = bytes(900)
        let file = try write("pick.bin", original)
        let output = try FileSplitting.split(file, partSize: 200, into: nil)
        try fm.removeItem(at: file)

        // From a later part.
        let fromPart = try FileSplitting.join(from: output.parts[2], into: nil)
        XCTAssertEqual(try Data(contentsOf: fromPart), original)

        // From the manifest.
        let fromManifest = try FileSplitting.join(from: output.manifest, into: nil)
        XCTAssertEqual(try Data(contentsOf: fromManifest), original)
    }

    func testJoinStepsPastANameAlreadyTaken() throws {
        let file = try write("keep.bin", bytes(200))
        let parts = try FileSplitting.split(file, partSize: 100, into: nil).parts
        // The original is still there, so the join must not overwrite it.
        let joined = try FileSplitting.join(from: parts[0], into: nil)
        XCTAssertEqual(joined.lastPathComponent, "keep (2).bin")
        XCTAssertEqual(try Data(contentsOf: file), bytes(200))        // untouched
        XCTAssertEqual(try Data(contentsOf: joined), bytes(200))
    }

    // MARK: - Missing and corrupted parts

    func testAManifestCatchesAMissingPart() throws {
        let file = try write("gap.bin", bytes(500))
        let output = try FileSplitting.split(file, partSize: 100, into: nil)
        XCTAssertEqual(output.parts.count, 5)
        // Delete a part in the middle; the manifest still lists all five.
        try fm.removeItem(at: output.parts[2])
        XCTAssertThrowsError(try FileSplitting.join(from: output.parts[0], into: nil)) { error in
            guard case FileSplitting.Failure.missingParts(let names) = error else {
                return XCTFail("expected missingParts, got \(error)")
            }
            XCTAssertEqual(names, ["gap.bin.003"])
        }
    }

    func testAManifestCatchesACorruptedPart() throws {
        let file = try write("rot.bin", bytes(400))
        let output = try FileSplitting.split(file, partSize: 100, into: nil)
        // Scribble over the second part, keeping its length.
        try bytes(100).write(to: output.parts[1])      // different bytes than the original slice
        XCTAssertThrowsError(try FileSplitting.join(from: output.parts[0], into: nil)) { error in
            guard case FileSplitting.Failure.corruptParts(let names) = error else {
                return XCTFail("expected corruptParts, got \(error)")
            }
            XCTAssertEqual(names, ["rot.bin.002"])
        }
    }

    func testWithoutAManifestAMiddleGapIsStillCaught() throws {
        let file = try write("nomanifest.bin", bytes(500))
        let output = try FileSplitting.split(file, partSize: 100, into: nil)
        try fm.removeItem(at: output.manifest)          // no manifest to lean on
        try fm.removeItem(at: output.parts[2])          // 1,2,_,4,5 -- a hole
        XCTAssertThrowsError(try FileSplitting.join(from: output.parts[0], into: nil)) { error in
            guard case FileSplitting.Failure.missingParts(let names) = error else {
                return XCTFail("expected missingParts, got \(error)")
            }
            XCTAssertEqual(names, ["nomanifest.bin.003"])
        }
    }

    func testWithoutAManifestAMissingTrailingPartIsNotAnError() throws {
        // Nothing records how many parts there were, so the set simply ending
        // early cannot be told from being complete -- the join goes ahead with
        // what is there, as the user accepted.
        let file = try write("trailing.bin", bytes(500))
        let output = try FileSplitting.split(file, partSize: 100, into: nil)
        try fm.removeItem(at: output.manifest)
        try fm.removeItem(at: output.parts[4])          // drop the last of five
        let joined = try FileSplitting.join(from: output.parts[0], into: nil)
        XCTAssertEqual(try Data(contentsOf: joined).count, 400)
    }

    func testJoiningSomethingThatIsNotAPartThrows() throws {
        let notAPart = try write("whole.bin", bytes(10))
        XCTAssertThrowsError(try FileSplitting.join(from: notAPart, into: nil))
    }

    // MARK: - Not overwriting

    func testExistingOutputsNamesWhatASplitWouldOverwrite() throws {
        let file = try write("again.bin", bytes(250))
        XCTAssertTrue(FileSplitting.existingOutputs(file: file, partSize: 100, into: nil).isEmpty)

        _ = try FileSplitting.split(file, partSize: 100, into: nil)
        // A second split at the same size would land on the same names.
        let clash = FileSplitting.existingOutputs(file: file, partSize: 100, into: nil)
            .map(\.lastPathComponent).sorted()
        XCTAssertEqual(clash, ["again.bin.001", "again.bin.002", "again.bin.003",
                               "again.bin.diptychsplit.json"])
    }
}
