import XCTest
@testable import Diptych

/// The shadow of an SFTP server, against a fake server: what a folder shows,
/// when bytes arrive, and what is dropped when the server changes.
final class SFTPMirrorTests: XCTestCase {

    /// A server that is a dictionary: folders to their entries, files to their bytes.
    final class FakeServer: RemoteListing, @unchecked Sendable {
        var folders: [String: [SFTPEntry]]
        var files: [String: Data]
        private(set) var downloads: [String] = []

        init(folders: [String: [SFTPEntry]], files: [String: Data] = [:]) {
            self.folders = folders
            self.files = files
        }

        func entries(in path: String) async throws -> [SFTPEntry] {
            folders[path] ?? []
        }

        func download(_ path: String, to destination: URL) async throws {
            downloads.append(path)
            try (files[path] ?? Data()).write(to: destination)
        }
    }

    private func mirror(_ server: RemoteListing) -> SFTPMirror {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sftp-mirror-\(UUID().uuidString)")
        return SFTPMirror(root: root, remote: server, host: "nas")
    }

    private func node(_ mirror: SFTPMirror, _ path: String) async throws -> BrowserManifest.Node? {
        let folder = await mirror.localURL(for: path).deletingLastPathComponent()
        return BrowserManifestStore.read(in: folder)?.nodes.first {
            $0.name == URL(fileURLWithPath: path).lastPathComponent
        }
    }

    func testAListedFolderHoldsItsEntriesAsFoldersAndLockedPlaceholders() async throws {
        let server = FakeServer(folders: ["/home/peter": [
            SFTPEntry(name: "photos", kind: .directory, mode: 0o755),
            SFTPEntry(name: "note.txt", kind: .file, size: 12, mode: 0o644),
        ]])
        let shadow = mirror(server)
        let skipped = try await shadow.populate("/home/peter")
        XCTAssertEqual(skipped, [])

        let folder = await shadow.localURL(for: "/home/peter")
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("photos").path,
                                                     isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)

        let placeholder = folder.appendingPathComponent("note.txt")
        let size = try FileManager.default.attributesOfItem(atPath: placeholder.path)[.size] as? Int
        XCTAssertEqual(size, 0)
        let mode = try FileManager.default.attributesOfItem(atPath: placeholder.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o400)

        let note = try await node(shadow, "/home/peter/note.txt")
        XCTAssertEqual(note?.attribute(BrowserManifest.Attribute.size)?.intValue, 12)
        XCTAssertEqual(note?.attribute(BrowserManifest.Attribute.mode)?.intValue, 0o644)
        XCTAssertEqual(note?.backing, BrowserManifest.Backing.none)
        XCTAssertEqual(BrowserManifestStore.read(in: folder)?.origin["host"], "nas")
    }

    func testMaterializingFetchesTheBytesOnceAndRecordsThem() async throws {
        let server = FakeServer(folders: ["/d": [SFTPEntry(name: "a.txt", kind: .file, size: 5)]],
                                files: ["/d/a.txt": Data("hello".utf8)])
        let shadow = mirror(server)
        try await shadow.populate("/d")

        let file = try await shadow.materialize("/d/a.txt")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "hello")
        let again = try await shadow.materialize("/d/a.txt")
        XCTAssertEqual(again, file)
        XCTAssertEqual(server.downloads, ["/d/a.txt"])
        let recorded = try await node(shadow, "/d/a.txt")
        XCTAssertEqual(recorded?.backing, .file("a.txt"))
    }

    func testAFileThatChangedOnTheServerLosesItsBytes() async throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let server = FakeServer(folders: ["/d": [SFTPEntry(name: "a.txt", kind: .file, size: 5, modified: date)]],
                                files: ["/d/a.txt": Data("hello".utf8)])
        let shadow = mirror(server)
        try await shadow.populate("/d")
        _ = try await shadow.materialize("/d/a.txt")

        server.folders["/d"] = [SFTPEntry(name: "a.txt", kind: .file, size: 9, modified: date)]
        try await shadow.populate("/d")
        let after = try await node(shadow, "/d/a.txt")
        XCTAssertEqual(after?.backing, BrowserManifest.Backing.none)
        let placeholder = await shadow.localURL(for: "/d/a.txt").path
        let size = try FileManager.default.attributesOfItem(atPath: placeholder)[.size] as? Int
        XCTAssertEqual(size, 0)
    }

    func testAnEntryTheServerNoLongerListsIsRemoved() async throws {
        let server = FakeServer(folders: ["/d": [SFTPEntry(name: "a", kind: .file),
                                                 SFTPEntry(name: "b", kind: .file)]])
        let shadow = mirror(server)
        try await shadow.populate("/d")
        server.folders["/d"] = [SFTPEntry(name: "a", kind: .file)]
        try await shadow.populate("/d")
        let folder = await shadow.localURL(for: "/d")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("b").path))
        XCTAssertEqual(BrowserManifestStore.read(in: folder)?.nodes.map(\.name), ["a"])
    }

    func testNamesThatDifferOnlyInCaseAreSkippedOnceNotLost() async throws {
        let server = FakeServer(folders: ["/d": [SFTPEntry(name: "A.txt", kind: .file),
                                                 SFTPEntry(name: "a.txt", kind: .file)]])
        let shadow = mirror(server)
        let skipped = try await shadow.populate("/d")
        XCTAssertEqual(skipped, ["a.txt"])
        let folder = await shadow.localURL(for: "/d")
        XCTAssertEqual(BrowserManifestStore.read(in: folder)?.nodes.count, 1)
    }

    func testAServerNamedLikeTheManifestGetsAnotherManifestName() async throws {
        let server = FakeServer(folders: ["/d": [SFTPEntry(name: "__DIPTYCH.json", kind: .file)]])
        let shadow = mirror(server)
        try await shadow.populate("/d")
        let folder = await shadow.localURL(for: "/d")
        XCTAssertEqual(BrowserManifestStore.located(in: folder)?.fileName, "__1DIPTYCH.json")
        XCTAssertEqual(BrowserManifestStore.read(in: folder)?.nodes.map(\.name), ["__DIPTYCH.json"])
    }

    /// An unchanged folder must not be written again: the pane reloads on any
    /// change in its folder, so a rewrite would start a reload loop.
    func testAnUnchangedFolderIsNotWrittenAgain() async throws {
        let server = FakeServer(folders: ["/d": [SFTPEntry(name: "a.txt", kind: .file, size: 1)]])
        let shadow = mirror(server)
        try await shadow.populate("/d")
        let folder = await shadow.localURL(for: "/d")
        let manifest = BrowserManifestStore.located(in: folder)!.fileName
        let before = try FileManager.default.attributesOfItem(
            atPath: folder.appendingPathComponent(manifest).path)[.modificationDate] as? Date

        try await Task.sleep(for: .seconds(1.1))
        try await shadow.populate("/d")

        let after = try FileManager.default.attributesOfItem(
            atPath: folder.appendingPathComponent(manifest).path)[.modificationDate] as? Date
        XCTAssertEqual(before, after)
    }
}
