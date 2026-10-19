import XCTest
import Darwin
@testable import Diptych

/// ArchiveSource: an archive becomes a directory skeleton with per-directory
/// manifests and an opaque indexed backing store. The listing carries the
/// archive's own metadata, not the extracted copies'; the bytes are reachable
/// but locked.
final class ArchiveSourceTests: XCTestCase {

    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("DiptychArchiveSource-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        ArchiveSource.remove(root.appendingPathComponent("holder"))
        try? fm.removeItem(at: root)
    }

    /// `top/notes.txt` (0640), `top/2024/invoice.pdf`, `top/run` (setuid), in
    /// a zip.
    private func makeZip() throws -> URL {
        let top = root.appendingPathComponent("top")
        try fm.createDirectory(at: top.appendingPathComponent("2024"), withIntermediateDirectories: true)
        let notes = top.appendingPathComponent("notes.txt")
        try Data("notes".utf8).write(to: notes)
        XCTAssertEqual(chmod(notes.path, 0o640), 0)
        try Data("%PDF".utf8).write(to: top.appendingPathComponent("2024/invoice.pdf"))
        let run = top.appendingPathComponent("run")
        try Data("#!/bin/sh\n".utf8).write(to: run)
        XCTAssertEqual(chmod(run.path, 0o4755), 0)
        let zip = root.appendingPathComponent("p.zip")
        do { try Archiving.create([top], at: zip, options: Archiving.Options()) }
        catch { XCTFail(error.message) }
        return zip
    }

    private func build(_ archive: URL) throws -> ArchiveSource {
        let kind = try XCTUnwrap(Archiving.kind(of: archive))
        do {
            return try ArchiveSource.build(archive: archive, kind: kind,
                                           into: root.appendingPathComponent("holder"))
        } catch { XCTFail(error.message); throw error }
    }

    // MARK: -

    func testTheListingComesFromTheArchiveNotTheBackingFiles() throws {
        let source = try build(try makeZip())
        // The root holds the single top folder.
        let top = try XCTUnwrap(source.listing(of: "").first)
        XCTAssertEqual(top.name, "top")
        XCTAssertEqual(top.kind, .directory)

        let inside = source.listing(of: "top")
        XCTAssertEqual(Set(inside.map(\.name)), ["notes.txt", "2024", "run"])
        let notes = try XCTUnwrap(inside.first { $0.name == "notes.txt" })
        XCTAssertEqual(notes.kind, .file)
        XCTAssertEqual(notes.attribute(BrowserManifest.Attribute.mode)?.intValue, 0o640)
        XCTAssertEqual(notes.attribute(BrowserManifest.Attribute.size)?.intValue, 5)
        // The setuid bit the archive recorded is in the listing, though the
        // backing file was extracted without it.
        let run = try XCTUnwrap(inside.first { $0.name == "run" })
        XCTAssertEqual(run.attribute(BrowserManifest.Attribute.mode)?.intValue, 0o4755)
    }

    func testTheBackingIsTheExtractedFile() throws {
        let source = try build(try makeZip())
        let invoice = try XCTUnwrap(source.listing(of: "top/2024").first { $0.name == "invoice.pdf" })
        XCTAssertEqual(invoice.backing, .file("top/2024/invoice.pdf"))
        let file = try XCTUnwrap(source.localFile(for: invoice))
        XCTAssertEqual(file, source.root.appendingPathComponent("top/2024/invoice.pdf"))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "%PDF")
    }

    func testTheBackingIsLockedReadOnly() throws {
        let source = try build(try makeZip())
        let notes = try XCTUnwrap(source.listing(of: "top").first { $0.name == "notes.txt" })
        let file = try XCTUnwrap(source.localFile(for: notes))
        var info = stat()
        XCTAssertEqual(lstat(file.path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o400, "the extracted bytes are read-only")
    }

    func testEachDirectoryHasAManifestBesideTheRealFiles() throws {
        let source = try build(try makeZip())
        XCTAssertNotNil(BrowserManifestStore.read(in: source.root))
        XCTAssertNotNil(BrowserManifestStore.read(in: source.root.appendingPathComponent("top")))
        XCTAssertNotNil(BrowserManifestStore.read(in: source.root.appendingPathComponent("top/2024")))
        // The real files are there (name-mirror), with the manifest beside them.
        let topReal = try fm.contentsOfDirectory(atPath: source.root.appendingPathComponent("top").path)
        XCTAssertEqual(Set(topReal), ["__DIPTYCH.json", "notes.txt", "run", "2024"])
        XCTAssertFalse(source.capabilities.writable)
    }

    func testTheLoaderShowsArchivePermissionsAndHidesTheManifest() throws {
        let source = try build(try makeZip())
        let rows = try DirectoryLoader.list(directory: source.root.appendingPathComponent("top"),
                                            showHidden: true,
                                            columns: [.name, .permissions, .owner])
            .filter { !$0.isParent }
        XCTAssertFalse(rows.contains { $0.name == "__DIPTYCH.json" }, "the manifest is hidden")
        XCTAssertEqual(Set(rows.map(\.name)), ["notes.txt", "run", "2024"])
        // The archive's permissions, not the locked copy's 0400.
        XCTAssertEqual(rows.first { $0.name == "notes.txt" }?.permissions, "-rw-r-----")
        XCTAssertEqual(rows.first { $0.name == "run" }?.permissions, "-rwsr-xr-x",
                       "the setuid bit the extracted copy lost")
        // On disk the file is locked read-only, so the overlay really is from
        // the manifest and not from a stat.
        var info = stat()
        XCTAssertEqual(lstat(source.root.appendingPathComponent("top/notes.txt").path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o400)
    }

    func testAManifestNamedEntryDoesNotHideTheRealOne() throws {
        // An archive whose folder contains a file literally called
        // __DIPTYCH.json: it must still be listed.
        let top = root.appendingPathComponent("odd")
        try fm.createDirectory(at: top, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: top.appendingPathComponent("__DIPTYCH.json"))
        try Data("y".utf8).write(to: top.appendingPathComponent("b.txt"))
        let zip = root.appendingPathComponent("odd.zip")
        do { try Archiving.create([top], at: zip, options: Archiving.Options()) }
        catch { return XCTFail(error.message) }

        let source = try build(zip)
        let names = Set(source.listing(of: "odd").map(\.name))
        XCTAssertTrue(names.contains("__DIPTYCH.json"), "the archive\u{2019}s own file is listed")
        XCTAssertTrue(names.contains("b.txt"))
    }

    func testQuickLookOfAFolderHidesTheManifest() throws {
        let source = try build(try makeZip())
        let listing = Listing.folder(at: source.root.appendingPathComponent("top"))
        let names = Set(listing.entries.map(\.name))
        XCTAssertFalse(names.contains { BrowserManifestStore.number(of: $0) != nil },
                       "no manifest file in the Quick Look listing")
        XCTAssertEqual(names, ["notes.txt", "run", "2024"])
    }

    func testRemovalClearsTheLockedHolder() throws {
        let source = try build(try makeZip())
        XCTAssertTrue(fm.fileExists(atPath: source.holder.path))
        ArchiveSource.remove(source.holder)
        XCTAssertFalse(fm.fileExists(atPath: source.holder.path))
    }
}
