import XCTest
import Darwin
@testable import Diptych

/// Archive ▸ Open as Folder: an archive unpacked once into the caches and
/// shown as a read-only folder, the path bar naming it inside the archive.
@MainActor
final class ArchiveBrowsingTests: XCTestCase {

    private var root: URL!
    private var savedCacheRoot: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("DiptychBrowsing-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        savedCacheRoot = ArchiveBrowsing.cacheRoot
        ArchiveBrowsing.cacheRoot = root.appendingPathComponent("cache")
    }

    override func tearDownWithError() throws {
        ArchiveBrowsing.removeAll()
        ArchiveBrowsing.cacheRoot = savedCacheRoot
        try? fm.removeItem(at: root)
    }

    /// `downloads/photos.<ext>` holding `2024/a.txt` and `notes.txt`.
    private func archive(_ format: Archiving.Format, password: String? = nil,
                         encrypted: Bool = false) throws -> URL {
        let source = root.appendingPathComponent("src-\(UUID().uuidString)")
        try fm.createDirectory(at: source.appendingPathComponent("2024"), withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: source.appendingPathComponent("2024/a.txt"))
        try Data("notes".utf8).write(to: source.appendingPathComponent("notes.txt"))
        var options = Archiving.Options()
        options.format = format
        if encrypted, format == .zip { options.zipEncryption = .aes256 }
        if encrypted, format == .appleArchive { options.aarEncrypted = true }
        let downloads = root.appendingPathComponent("downloads")
        try fm.createDirectory(at: downloads, withIntermediateDirectories: true)
        let target = downloads.appendingPathComponent("photos.\(options.fileExtension)")
        do {
            try Archiving.create([source.appendingPathComponent("2024"),
                                  source.appendingPathComponent("notes.txt")],
                                 at: target, options: options, password: password)
        } catch { XCTFail(error.message) }
        return target
    }

    private func open(_ archive: URL, password: String? = nil) throws -> URL {
        let kind = try XCTUnwrap(Archiving.kind(of: archive))
        let secret = try password.map { password -> Archiving.PasswordFile in
            do { return try Archiving.PasswordFile(password, endsWithNewline: kind == .zip) }
            catch { throw error }
        }
        do { return try ArchiveBrowsing.open(archive, kind: kind, password: secret, job: Archiving.Job()) }
        catch { XCTFail(error.message); throw error }
    }

    private func text(_ url: URL) -> String? {
        (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) }
    }

    // MARK: -

    func testEachKindOpensAsAFolderNamedAfterIt() throws {
        for (format, encrypted, password) in [(Archiving.Format.zip, false, nil as String?),
                                               (.tar, false, nil), (.appleArchive, false, nil),
                                               (.zip, true, "s3cret"),
                                               (.appleArchive, true, "correct horse battery staple")] {
            let archive = try archive(format, password: password, encrypted: encrypted)
            let folder = try open(archive, password: password)
            XCTAssertEqual(folder.lastPathComponent, archive.lastPathComponent)
            XCTAssertTrue(ArchiveBrowsing.isInside(folder))
            XCTAssertEqual(text(folder.appendingPathComponent("2024/a.txt")), "hello", "\(format)")
            XCTAssertEqual(text(folder.appendingPathComponent("notes.txt")), "notes", "\(format)")
            XCTAssertFalse(fm.fileExists(atPath: folder.appendingPathComponent("__MACOSX").path))
            ArchiveBrowsing.removeAll()
            try? fm.removeItem(at: archive)
        }
    }

    func testThePathIsShownInsideTheArchiveAndLeadsBack() throws {
        let archive = try archive(.zip)
        let folder = try open(archive)
        let inner = folder.appendingPathComponent("2024")
        XCTAssertEqual(ArchiveBrowsing.shown(inner).path, archive.path + "/2024")
        XCTAssertEqual(ArchiveBrowsing.shown(folder).path, archive.path)
        XCTAssertEqual(ArchiveBrowsing.actual(URL(fileURLWithPath: archive.path + "/2024"))?.path, inner.path)
        XCTAssertEqual(ArchiveBrowsing.actual(archive)?.path, folder.path)
        XCTAssertNil(ArchiveBrowsing.actual(root))
        XCTAssertEqual(ArchiveBrowsing.shown(root), root, "anywhere else as it is")
    }

    func testAZipInAZipIsShownInsideBoth() throws {
        let inner = try archive(.zip)
        let outerSource = root.appendingPathComponent("outer")
        try fm.createDirectory(at: outerSource, withIntermediateDirectories: true)
        try fm.moveItem(at: inner, to: outerSource.appendingPathComponent("inner.zip"))
        let outer = root.appendingPathComponent("outer.zip")
        do { try Archiving.create([outerSource.appendingPathComponent("inner.zip")], at: outer,
                                  options: Archiving.Options()) }
        catch { return XCTFail(error.message) }

        let outerFolder = try open(outer)
        let innerFolder = try open(outerFolder.appendingPathComponent("inner.zip"))
        let shown = ArchiveBrowsing.shown(innerFolder.appendingPathComponent("2024"))
        XCTAssertEqual(shown.path, outer.path + "/inner.zip/2024")
        XCTAssertEqual(ArchiveBrowsing.actual(shown)?.path, innerFolder.appendingPathComponent("2024").path)
    }

    func testInsideIsAReadOnlyVolumeNamedAfterTheArchive() throws {
        let archive = try archive(.tar)
        let folder = try open(archive)
        let facts = VolumeFacts.of(folder.appendingPathComponent("2024"))
        XCTAssertTrue(facts.isReadOnly)
        XCTAssertEqual(facts.name, archive.lastPathComponent)
        XCTAssertFalse(VolumeFacts.of(root).isReadOnly)
    }

    func testAnUnchangedArchiveIsNotUnpackedAgainAndAChangedOneIs() throws {
        let archive = try archive(.zip)
        let first = try open(archive)
        XCTAssertEqual(ArchiveBrowsing.existing(for: archive), first)
        XCTAssertEqual(try open(archive), first)

        // Written again: another archive under the same name.
        try fm.removeItem(at: archive)
        let replacement = try self.archive(.zip)
        XCTAssertEqual(replacement, archive)
        XCTAssertNil(ArchiveBrowsing.existing(for: archive))
        XCTAssertNotEqual(try open(archive), first)
    }

    func testUpFromTheTopLandsBesideTheArchiveOnIt() async throws {
        let archive = try archive(.zip)
        let folder = try open(archive)
        let pane = PaneModel(directory: folder)
        await pane.reloadAndWait()
        XCTAssertTrue(pane.rows.contains { $0.name == "notes.txt" })
        pane.goUp()
        XCTAssertEqual(pane.directory.standardizedFileURL, archive.deletingLastPathComponent().standardizedFileURL)
        XCTAssertEqual(pane.pendingSelection, [archive])
    }

    func testUpFromDeepInsideStepsOutBesideTheArchiveNotIntoTheCache() async throws {
        // Going up through a subfolder arrives at the archive's top with a
        // trailing slash on the path. A URL-equality check missed that and let
        // the next Up overshoot into the caches folder. It must leave instead.
        let archive = try archive(.zip)
        let folder = try open(archive)
        let pane = PaneModel(directory: folder.appendingPathComponent("2024"))
        await pane.reloadAndWait()
        pane.goUp()
        await pane.reloadAndWait()
        XCTAssertEqual(pane.directory.standardizedFileURL.path, folder.standardizedFileURL.path,
                       "up from the subfolder lands on the archive's top")
        pane.goUp()
        XCTAssertEqual(pane.directory.standardizedFileURL.path,
                       archive.deletingLastPathComponent().standardizedFileURL.path,
                       "up from the top leaves the archive, not into the caches folder")
        XCTAssertFalse(ArchiveBrowsing.isInside(pane.directory))
        XCTAssertEqual(pane.pendingSelection, [archive])
    }

    func testThePaneIsSavedBesideTheArchive() async throws {
        let archive = try archive(.zip)
        let folder = try open(archive)
        let pane = PaneModel(directory: folder.appendingPathComponent("2024"))
        XCTAssertEqual(pane.snapshot.directory, archive.deletingLastPathComponent().path)
    }

    func testReadOnlyFoldersAreRemovedToo() throws {
        let folder = root.appendingPathComponent("cache/x/locked")
        try fm.createDirectory(at: folder.appendingPathComponent("inner"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: folder.appendingPathComponent("inner/f"))
        XCTAssertEqual(chmod(folder.appendingPathComponent("inner").path, 0o555), 0)
        XCTAssertEqual(chmod(folder.path, 0o555), 0)
        ArchiveBrowsing.removeAll()
        XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent("cache").path))
    }

    func testACopyOutGetsTheArchivePermissionsNotTheLock() throws {
        // A zip with a 0640 file and a setuid program.
        let src = root.appendingPathComponent("perms")
        try fm.createDirectory(at: src.appendingPathComponent("bin"), withIntermediateDirectories: true)
        let notes = src.appendingPathComponent("notes.txt")
        try Data("notes".utf8).write(to: notes)
        XCTAssertEqual(chmod(notes.path, 0o640), 0)
        let run = src.appendingPathComponent("bin/run")
        try Data("#!/bin/sh\n".utf8).write(to: run)
        XCTAssertEqual(chmod(run.path, 0o4755), 0)
        let zip = root.appendingPathComponent("perms.zip")
        do { try Archiving.create([src], at: zip, options: Archiving.Options()) }
        catch { return XCTFail(error.message) }

        let folder = try open(zip)
        func mode(_ url: URL) -> mode_t { var i = stat(); lstat(url.path, &i); return i.st_mode & 0o7777 }
        // In the opened archive the file is locked read-only.
        XCTAssertEqual(mode(folder.appendingPathComponent("perms/notes.txt")), 0o400)

        // A file copied out is given the archive's mode, writable again.
        let copiedFile = root.appendingPathComponent("out-notes.txt")
        try fm.copyItem(at: folder.appendingPathComponent("perms/notes.txt"), to: copiedFile)
        ArchiveBrowsing.unlockCopy(at: copiedFile,
                                   from: folder.appendingPathComponent("perms/notes.txt"))
        XCTAssertEqual(mode(copiedFile), 0o640)

        // A folder copied out gets each item's recorded mode, setuid included.
        let copiedDir = root.appendingPathComponent("out-perms")
        try fm.copyItem(at: folder.appendingPathComponent("perms"), to: copiedDir)
        ArchiveBrowsing.unlockCopy(at: copiedDir, from: folder.appendingPathComponent("perms"))
        XCTAssertEqual(mode(copiedDir.appendingPathComponent("notes.txt")), 0o640)
        XCTAssertEqual(mode(copiedDir.appendingPathComponent("bin/run")), 0o4755,
                       "the setuid bit is restored on the copy")
    }

    func testArchivesAndImagesOpenAsFolders() {
        for name in ["a.zip", "a.tar.gz", "a.tgz", "a.aar", "a.aea", "a.dmg", "a.iso"] {
            XCTAssertTrue(AppModel.opensAsFolder(URL(fileURLWithPath: "/x/" + name)), name)
        }
        XCTAssertFalse(AppModel.opensAsFolder(URL(fileURLWithPath: "/x/a.txt")))
    }
}
