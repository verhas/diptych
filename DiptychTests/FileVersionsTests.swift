import XCTest
import Darwin
@testable import Diptych

/// File ▸ Previous Versions…: reading a file's earlier selves out of APFS
/// snapshots, and restoring one in place as an undoable content change.
final class FileVersionsTests: XCTestCase {

    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("DiptychVersions-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        FileVersions.scanBases = savedBases
        try? fm.removeItem(at: root)
    }

    private lazy var savedBases = FileVersions.scanBases

    /// A synthetic snapshot of `file` holding `contents`, laid out the way the
    /// system exposes them -- `<base>/<machine>/<timestamp>/[<volume>/]<tail>`.
    @discardableResult
    private func plantSnapshot(of file: URL, stamp: String, volumeName: String?,
                               contents: String, modified: Date? = nil) throws -> URL {
        let base = root.appendingPathComponent("tm")
        FileVersions.scanBases = [base.path]
        var dir = base.appendingPathComponent("MACHINE-UUID").appendingPathComponent(stamp)
        if let volumeName { dir = dir.appendingPathComponent(volumeName) }
        // The file's path without its leading slash is the tail that repeats
        // inside a snapshot of its volume.
        let tail = String(file.standardizedFileURL.path.drop(while: { $0 == "/" }))
        let placed = dir.appendingPathComponent(tail)
        try fm.createDirectory(at: placed.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: placed)
        if let modified {
            try fm.setAttributes([.modificationDate: modified], ofItemAtPath: placed.path)
        }
        return placed
    }

    // MARK: - Reading snapshot timestamps

    func testDatesAreReadFromSnapshotNamesHoweverTheyAreWrapped() {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        formatter.timeZone = .current
        let expected = formatter.date(from: "2026-10-19-063000")

        XCTAssertEqual(FileVersions.date(fromStamp: "2026-10-19-063000"), expected)
        XCTAssertEqual(FileVersions.date(fromStamp: "2026-10-19-063000.backup"), expected)
        XCTAssertEqual(FileVersions.date(fromStamp: "com.apple.TimeMachine.2026-10-19-063000.local"),
                       expected)
    }

    func testNonTimestampNamesHaveNoDate() {
        XCTAssertNil(FileVersions.date(fromStamp: "Macintosh HD - Data"))
        XCTAssertNil(FileVersions.date(fromStamp: "2026-10-19"))          // too short
        XCTAssertNil(FileVersions.date(fromStamp: "12026-10-19-0630000")) // digits run too long
        XCTAssertNil(FileVersions.date(fromStamp: "snapshots"))
    }

    // MARK: - Listing

    func testAFreshFileHasNoVersionsAndIsToldWhy() {
        // A file created this instant cannot be in any snapshot, so the list is
        // empty -- and never nil-noted, so the window always has something to
        // say rather than an unexplained blank.
        let file = root.appendingPathComponent("brand-new-\(UUID().uuidString).txt")
        try? Data("now".utf8).write(to: file)
        let listing = FileVersions.list(for: file)
        XCTAssertTrue(listing.versions.isEmpty)
        XCTAssertNotNil(listing.note)
    }

    func testVersionsAreFoundWhateverTheSnapshotLayoutAndNewestFirst() throws {
        let file = root.appendingPathComponent("doc.txt")
        try Data("current".utf8).write(to: file)

        // The three layouts the system actually uses: directly under the
        // timestamp folder, under `Data` (a local snapshot), and under a
        // volume-named folder with a `.backup` suffix on the stamp (a Time
        // Machine backup). All three must be found.
        // Distinct contents (distinct lengths, so distinct signatures) so none
        // is collapsed into another.
        try plantSnapshot(of: file, stamp: "2026-10-18-090000",
                          volumeName: nil, contents: "v1")
        try plantSnapshot(of: file, stamp: "2026-10-19-070000",
                          volumeName: "Data", contents: "v2 longer")
        try plantSnapshot(of: file, stamp: "2026-10-19-090000.backup",
                          volumeName: "Macintosh HD - Data", contents: "v3 the longest!!")

        let listing = FileVersions.list(for: file)
        XCTAssertEqual(listing.versions.count, 3)
        // Newest first.
        XCTAssertEqual(listing.versions.map(\.date), listing.versions.map(\.date).sorted(by: >))
        XCTAssertTrue(listing.versions.allSatisfy(\.isAvailable))

        // Each points at the right bytes, so Compare and Restore read the real
        // earlier contents.
        let newest = try XCTUnwrap(listing.versions.first?.url)
        XCTAssertEqual(try String(contentsOf: newest, encoding: .utf8), "v3 the longest!!")
    }

    func testRunsWhereTheFileNeverChangedCollapseToTheMomentItLastDid() throws {
        let file = root.appendingPathComponent("rarely.txt")
        try Data("current".utf8).write(to: file)

        // Five hourly snapshots: the same bytes (same size and modification
        // date) in the first three, then a change kept for the last two.
        let old = Date(timeIntervalSince1970: 1_700_000_000)
        let newer = Date(timeIntervalSince1970: 1_700_500_000)
        try plantSnapshot(of: file, stamp: "2026-10-19-060000", volumeName: "Data",
                          contents: "steady", modified: old)
        try plantSnapshot(of: file, stamp: "2026-10-19-070000", volumeName: "Data",
                          contents: "steady", modified: old)
        try plantSnapshot(of: file, stamp: "2026-10-19-080000", volumeName: "Data",
                          contents: "steady", modified: old)
        try plantSnapshot(of: file, stamp: "2026-10-19-090000", volumeName: "Data",
                          contents: "changed now", modified: newer)
        try plantSnapshot(of: file, stamp: "2026-10-19-100000", volumeName: "Data",
                          contents: "changed now", modified: newer)

        let listing = FileVersions.list(for: file)
        // Two distinct contents, so two versions, newest of each run kept.
        XCTAssertEqual(listing.versions.count, 2)
        XCTAssertEqual(listing.versions.first.flatMap { try? String(contentsOf: $0.url!, encoding: .utf8) },
                       "changed now")
        XCTAssertEqual(listing.versions.last.flatMap { try? String(contentsOf: $0.url!, encoding: .utf8) },
                       "steady")
    }

    // MARK: - Restoring

    func testRestorePutsTheOldBytesBackKeepingTheFileItself() throws {
        // The file as it is now, with a mode and an extended attribute of its
        // own, and a separate "version" standing in for the copy in a snapshot.
        let file = root.appendingPathComponent("notes.txt")
        try Data("new contents".utf8).write(to: file)
        XCTAssertEqual(chmod(file.path, 0o640), 0)
        try file.withUnsafeFileSystemRepresentation { path in
            let value = Data("green".utf8)
            _ = value.withUnsafeBytes { setxattr(path, "com.apple.metadata:kColour", $0.baseAddress, $0.count, 0, 0) }
        }

        let version = root.appendingPathComponent("version.txt")
        try Data("old contents".utf8).write(to: version)

        let before = try FileVersions.restore(version, over: file)

        // The file now holds the old bytes, but is the same file: its mode and
        // its attribute are untouched -- only the contents changed.
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "old contents")
        var info = stat()
        XCTAssertEqual(stat(file.path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o640)
        XCTAssertEqual(readXattr("com.apple.metadata:kColour", of: file), Data("green".utf8))

        // `before` is a copy of what it held, for Undo: putting it back returns
        // the file to exactly its earlier contents.
        XCTAssertEqual(try String(contentsOf: before, encoding: .utf8), "new contents")
        try UndoSnapshots.putBack(before, into: file)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "new contents")
        XCTAssertEqual(readXattr("com.apple.metadata:kColour", of: file), Data("green".utf8))
    }

    func testRestoreFromAnUnreadableVersionThrowsAndLeavesTheFile() throws {
        let file = root.appendingPathComponent("keep.txt")
        try Data("safe".utf8).write(to: file)
        let missing = root.appendingPathComponent("not-there.txt")
        XCTAssertThrowsError(try FileVersions.restore(missing, over: file))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "safe")
    }

    // MARK: -

    private func readXattr(_ name: String, of url: URL) -> Data? {
        url.withUnsafeFileSystemRepresentation { path -> Data? in
            let length = getxattr(path, name, nil, 0, 0, 0)
            guard length >= 0 else { return nil }
            var data = Data(count: length)
            let read = data.withUnsafeMutableBytes { getxattr(path, name, $0.baseAddress, length, 0, 0) }
            return read >= 0 ? data : nil
        }
    }
}
