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
            (folders[path] ?? []).map { entry in
                let child = path == "/" ? "/" + entry.name : path + "/" + entry.name
                return SFTPEntry(name: entry.name, kind: entry.kind, size: entry.size,
                                    mode: modes[child] ?? entry.mode)
            }
        }

        func download(_ path: String, to destination: URL) async throws {
            downloads.append(path)
            try (files[path] ?? Data()).write(to: destination)
        }

        func makeDirectory(_ path: String) async throws {
            folders[path] = folders[path] ?? []
            link(path, .directory)
        }

        func removeFile(_ path: String) async throws {
            files[path] = nil
            unlink(path)
        }

        func removeDirectory(_ path: String) async throws {
            folders[path] = nil
            unlink(path)
        }

        func rename(_ from: String, to: String) async throws {
            if let data = files.removeValue(forKey: from) {
                files[to] = data
                unlink(from)
                link(to, .file)
            } else if let entries = folders.removeValue(forKey: from) {
                folders[to] = entries
                unlink(from)
                link(to, .directory)
            }
        }

        func upload(_ local: URL, to path: String) async throws {
            files[path] = try Data(contentsOf: local)
            link(path, .file)
        }

        private(set) var modes: [String: UInt32] = [:]

        func setPermissions(_ path: String, mode: UInt32) async throws {
            modes[path] = mode
        }

        /// Lists `path` in its folder, as the server would.
        private func link(_ path: String, _ kind: SFTPEntry.Kind) {
            let (folder, name) = Self.split(path)
            folders[folder, default: []].removeAll { $0.name == name }
            folders[folder, default: []].append(SFTPEntry(name: name, kind: kind))
        }

        private func unlink(_ path: String) {
            let (folder, name) = Self.split(path)
            folders[folder]?.removeAll { $0.name == name }
        }

        private static func split(_ path: String) -> (String, String) {
            let index = path.lastIndex(of: "/")!
            let folder = String(path[..<index])
            return (folder.isEmpty ? "/" : folder, String(path[path.index(after: index)...]))
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
