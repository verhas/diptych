import XCTest
import AppKit
@testable import Diptych

/// ⌘C on an item of an opened archive, pasted elsewhere: whoever pastes gets
/// a clean copy, made at the paste, never the locked cache. On a pasteboard
/// of the test's own, so the person's clipboard is left alone.
@MainActor
final class ArchiveClipboardTests: XCTestCase {

    private var root: URL!
    private var savedCacheRoot: URL!
    private var pasteboard: NSPasteboard!
    private let fm = FileManager.default

    override func setUp() async throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("DiptychClipboard-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        savedCacheRoot = ArchiveBrowsing.cacheRoot
        ArchiveBrowsing.cacheRoot = root.appendingPathComponent("cache")
        pasteboard = NSPasteboard(name: NSPasteboard.Name("DiptychClipboardTests-\(UUID().uuidString)"))
    }

    override func tearDown() async throws {
        pasteboard.releaseGlobally()
        ArchiveBrowsing.unpinHandedOut()
        ArchiveBrowsing.removeAll()
        ArchiveBrowsing.removeHandedOut()
        ArchiveBrowsing.cacheRoot = savedCacheRoot
        try? fm.removeItem(at: root)
    }

    /// An opened zip holding `kit/sub/a.txt`, and the item `kit` in it.
    private func archiveItem() throws -> URL {
        let src = root.appendingPathComponent("kit")
        try fm.createDirectory(at: src.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try Data("a".utf8).write(to: src.appendingPathComponent("sub/a.txt"))
        let zip = root.appendingPathComponent("kit.zip")
        do { try Archiving.create([src], at: zip, options: Archiving.Options()) }
        catch { XCTFail(error.message) }
        let folder = try ArchiveBrowsing.open(zip, kind: XCTUnwrap(Archiving.kind(of: zip)),
                                              password: nil, job: Archiving.Job())
        return folder.appendingPathComponent("kit")
    }

    private func pastedURL() -> URL? {
        // What another app reads: the plain file URL.
        pasteboard.readObjects(forClasses: [NSURL.self],
                               options: [.urlReadingFileURLsOnly: true])?.first as? URL
    }

    private func mode(_ url: URL) -> mode_t {
        var info = stat()
        lstat(url.path, &info)
        return info.st_mode & 0o7777
    }

    func testAPasteElsewhereGetsACleanCopyMadeAtThePaste() throws {
        let item = try archiveItem()
        Clipboard.write([item], to: pasteboard)
        XCTAssertFalse(fm.fileExists(atPath: ArchiveBrowsing.handOutRoot.path),
                       "nothing is made until something pastes")

        let pasted = try XCTUnwrap(pastedURL())
        XCTAssertNotEqual(pasted.standardizedFileURL, item.standardizedFileURL)
        XCTAssertFalse(ArchiveBrowsing.isInside(pasted))
        XCTAssertEqual(mode(pasted.appendingPathComponent("sub")) & 0o200, 0o200,
                       "the archive's permissions, not the cache's lock")
        XCTAssertEqual(pastedURL(), pasted, "pasted again, the same copy")
    }

    func testAPasteInDiptychIsOfTheArchiveItemAndMakesNoCopy() throws {
        let item = try archiveItem()
        let plain = root.appendingPathComponent("plain.txt")
        try Data("p".utf8).write(to: plain)
        Clipboard.write([item, plain], to: pasteboard)

        XCTAssertEqual(Clipboard.fileURLs(on: pasteboard).map(\.standardizedFileURL),
                       [item.standardizedFileURL, plain.standardizedFileURL])
        XCTAssertFalse(fm.fileExists(atPath: ArchiveBrowsing.handOutRoot.path))
    }

    func testAtQuitTheCopyIsMadeAndOutlivesTheArchive() throws {
        let item = try archiveItem()
        Clipboard.write([item], to: pasteboard)

        Clipboard.settleArchiveItems(on: pasteboard)
        ArchiveBrowsing.removeAll()
        // Diptych's own paste, the archive gone: the copy.
        let back = try XCTUnwrap(Clipboard.fileURLs(on: pasteboard).first)
        XCTAssertFalse(ArchiveBrowsing.isInside(back))
        XCTAssertTrue(fm.fileExists(atPath: back.appendingPathComponent("sub/a.txt").path))

        // A day-old clean-up, or the next launch, leaves it while it is on
        // the clipboard.
        ArchiveBrowsing.removeHandedOut(olderThan: 0)
        XCTAssertTrue(fm.fileExists(atPath: back.path), "the clipboard holds it")
        ArchiveBrowsing.unpinHandedOut()
        ArchiveBrowsing.removeHandedOut(keeping: [back.standardizedFileURL.path])
        XCTAssertTrue(fm.fileExists(atPath: back.path), "kept at launch while on the clipboard")
        ArchiveBrowsing.removeHandedOut()
        XCTAssertFalse(fm.fileExists(atPath: back.path))
    }
}
