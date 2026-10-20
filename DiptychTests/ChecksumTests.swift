import XCTest
import CryptoKit
@testable import Diptych

/// Checksum ▸ Create and Check: computing a file's sums, writing and reading
/// the little `name.ext` files, and matching a sum found in the clipboard.
final class ChecksumTests: XCTestCase {

    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("DiptychChecksums-\(UUID().uuidString)")
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

    // MARK: - Hashing

    /// Known vectors for "abc", so a wrong hex rendering (byte order, casing,
    /// missing leading zero) is caught, not just a mismatch with itself.
    func testDigestsMatchTheKnownVectorsForABC() throws {
        let file = try write("abc.txt", "abc")
        XCTAssertEqual(Checksums.digest(of: file, algorithm: .md5),
                       "900150983cd24fb0d6963f7d28e17f72")
        XCTAssertEqual(Checksums.digest(of: file, algorithm: .sha1),
                       "a9993e364706816aba3e25717850c26c9cd0d89d")
        XCTAssertEqual(Checksums.digest(of: file, algorithm: .sha256),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(
            Checksums.digest(of: file, algorithm: .sha512),
            "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a"
            + "2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f")
    }

    func testAllDigestsAgreeWithTheOneAtATimeDigests() throws {
        let file = try write("blob.bin", String(repeating: "Diptych ", count: 5000))
        let all = try XCTUnwrap(Checksums.allDigests(of: file))
        for algorithm in Checksums.Algorithm.allCases {
            XCTAssertEqual(all[algorithm], Checksums.digest(of: file, algorithm: algorithm),
                           "\(algorithm.label) one-pass differs from single")
            XCTAssertEqual(all[algorithm]?.count, algorithm.hexLength)
        }
    }

    func testDigestOfAnUnreadableFileIsNil() {
        let missing = root.appendingPathComponent("not-there.txt")
        XCTAssertNil(Checksums.digest(of: missing, algorithm: .sha256))
        XCTAssertNil(Checksums.allDigests(of: missing))
    }

    // MARK: - The checksum file

    func testTheChecksumFileIsNamedAndWrittenTheWayShasumReadsIt() throws {
        let file = try write("photo.jpg", "pixels")
        let url = Checksums.checksumURL(for: file, in: root, algorithm: .sha256)
        XCTAssertEqual(url.lastPathComponent, "photo.jpg.sha256")

        let hash = try XCTUnwrap(Checksums.digest(of: file, algorithm: .sha256))
        // `hash  name\n` -- two spaces, as coreutils writes it.
        XCTAssertEqual(Checksums.fileBody(hash: hash, name: "photo.jpg"),
                       "\(hash)  photo.jpg\n")
    }

    func testStoredHashIsReadFromCoreutilsAndBSDLayouts() throws {
        let hash = String(repeating: "a", count: 64)
        let coreutils = try write("a.sha256", "\(hash)  file.bin\n")
        XCTAssertEqual(Checksums.storedHash(in: coreutils, algorithm: .sha256), hash)

        let bsd = try write("b.sha256", "SHA256 (file.bin) = \(hash)\n")
        XCTAssertEqual(Checksums.storedHash(in: bsd, algorithm: .sha256), hash)

        // A 64-run is not an MD5 (32): the length must be the kind's own.
        XCTAssertNil(Checksums.storedHash(in: coreutils, algorithm: .md5))
    }

    // MARK: - Reading a sum out of text

    func testHashTokensFindSumsAndIgnoreOtherHexRuns() {
        let md5 = String(repeating: "f", count: 32)
        let sha256 = String(repeating: "0", count: 64)
        let tokens = Checksums.hashTokens(in: "see \(md5) and \(sha256), build #deadbeef here")
        XCTAssertTrue(tokens.contains(md5))
        XCTAssertTrue(tokens.contains(sha256))
        // "deadbeef" is 8 hex -- no hash is that length.
        XCTAssertFalse(tokens.contains("deadbeef"))
        XCTAssertFalse(Checksums.hasChecksum("just some words, nothing hex and long"))
    }

    func testMatchPicksTheStrongestKindPresentInTheClipboard() throws {
        let file = try write("doc.txt", "the quick brown fox")
        let digests = try XCTUnwrap(Checksums.allDigests(of: file))

        // Both the MD5 and the SHA-256 copied: the SHA-256 is the one named.
        let both = "\(digests[.md5]!)\n\(digests[.sha256]!)"
        XCTAssertEqual(Checksums.match(digests: digests, clipboard: both), .sha256)

        // Just the MD5, upper-cased, inside a sentence: still matched.
        let md5Line = "md5 is \(digests[.md5]!.uppercased()) ok"
        XCTAssertEqual(Checksums.match(digests: digests, clipboard: md5Line), .md5)

        // A sum of the right length but not this file's: no match.
        XCTAssertNil(Checksums.match(digests: digests,
                                     clipboard: String(repeating: "b", count: 64)))
        XCTAssertNil(Checksums.match(digests: digests, clipboard: "nothing here"))
    }

    // MARK: - Checking against the files beside each file

    func testCheckAgainstFilesReportsEachChecksumFileAsMatchOrNot() throws {
        let file = try write("data.bin", "payload")
        let sha256 = try XCTUnwrap(Checksums.digest(of: file, algorithm: .sha256))
        let md5 = try XCTUnwrap(Checksums.digest(of: file, algorithm: .md5))

        // A right SHA-256 and a wrong MD5 beside the same file.
        try write("data.bin.sha256", Checksums.fileBody(hash: sha256, name: "data.bin"))
        try write("data.bin.md5",
                  Checksums.fileBody(hash: String(repeating: "0", count: 32), name: "data.bin"))
        _ = md5

        let report = Checksums.checkAgainstFiles([file])
        XCTAssertEqual(report.checks.count, 2)
        XCTAssertFalse(report.allMatched)       // the MD5 is wrong
        XCTAssertTrue(report.anyMatched)        // the SHA-256 is right
        XCTAssertEqual(report.checks.first { $0.algorithm == .sha256 }?.matched, true)
        XCTAssertEqual(report.checks.first { $0.algorithm == .md5 }?.matched, false)
    }

    func testCheckAgainstFilesIsEmptyWhenNothingIsBesideTheFiles() throws {
        let file = try write("lonely.txt", "no sums here")
        let report = Checksums.checkAgainstFiles([file])
        XCTAssertTrue(report.checks.isEmpty)
        XCTAssertFalse(report.allMatched)
        XCTAssertFalse(report.anyMatched)
    }

    // MARK: - Planning a create against what is already there

    func testClassifySeesFreshMatchingAndStaleChecksumFiles() throws {
        let fresh = try write("fresh.txt", "needs one")
        let good = try write("good.txt", "already summed")
        let stale = try write("stale.txt", "changed since")

        // `good` has a right SHA-256 beside it; `stale` has a wrong one; `fresh`
        // has none.
        try write("good.txt.sha256",
                  Checksums.fileBody(hash: Checksums.digest(of: good, algorithm: .sha256)!,
                                     name: "good.txt"))
        try write("stale.txt.sha256",
                  Checksums.fileBody(hash: String(repeating: "0", count: 64), name: "stale.txt"))

        let plan = Checksums.classify(algorithm: .sha256,
                                      targets: [fresh, good, stale], folder: nil)
        XCTAssertEqual(plan.fresh.map { $0.target.lastPathComponent }, ["fresh.txt"])
        XCTAssertEqual(plan.upToDate, 1)
        XCTAssertEqual(plan.mismatched.map { $0.target.lastPathComponent }, ["stale.txt"])
        XCTAssertTrue(plan.problems.isEmpty)

        // The stale write carries the newly computed, correct sum -- what an
        // overwrite would put there.
        XCTAssertEqual(plan.mismatched.first?.hash,
                       Checksums.digest(of: stale, algorithm: .sha256))
    }

    func testWriteAllThenReclassifyShowsEverythingUpToDate() throws {
        let a = try write("a.txt", "alpha")
        let b = try write("b.txt", "bravo")
        let first = Checksums.classify(algorithm: .md5, targets: [a, b], folder: nil)
        XCTAssertEqual(first.fresh.count, 2)

        let made = Checksums.writeAll(first.fresh)
        XCTAssertEqual(made.made.count, 2)
        XCTAssertTrue(made.problems.isEmpty)

        // Nothing left to do the second time around.
        let again = Checksums.classify(algorithm: .md5, targets: [a, b], folder: nil)
        XCTAssertTrue(again.fresh.isEmpty)
        XCTAssertTrue(again.mismatched.isEmpty)
        XCTAssertEqual(again.upToDate, 2)

        // A file that then changes makes its checksum file stale.
        try Data("alpha, edited".utf8).write(to: a)
        let third = Checksums.classify(algorithm: .md5, targets: [a, b], folder: nil)
        XCTAssertEqual(third.mismatched.map { $0.target.lastPathComponent }, ["a.txt"])
        XCTAssertEqual(third.upToDate, 1)
    }

    func testClassifyCanSendChecksumFilesToAnotherFolder() throws {
        let file = try write("payload.bin", "ship it")
        let other = root.appendingPathComponent("other")
        try fm.createDirectory(at: other, withIntermediateDirectories: true)

        let plan = Checksums.classify(algorithm: .sha256, targets: [file], folder: other)
        XCTAssertEqual(plan.fresh.first?.destination,
                       other.appendingPathComponent("payload.bin.sha256"))
    }

    func testCheckAgainstFilesSpansSeveralFiles() throws {
        let a = try write("a.txt", "alpha")
        let b = try write("b.txt", "bravo")
        try write("a.txt.sha256",
                  Checksums.fileBody(hash: Checksums.digest(of: a, algorithm: .sha256)!, name: "a.txt"))
        try write("b.txt.sha256",
                  Checksums.fileBody(hash: Checksums.digest(of: b, algorithm: .sha256)!, name: "b.txt"))

        let report = Checksums.checkAgainstFiles([a, b])
        XCTAssertEqual(report.checks.count, 2)
        XCTAssertTrue(report.allMatched)
    }
}
