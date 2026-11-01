import CryptoKit
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

        /// Run while a listing is on its way: what happens here meanwhile.
        var duringListing: (() -> Void)?

        func entries(in path: String) async throws -> [SFTPEntry] {
            duringListing?()
            duringListing = nil
            return (folders[path] ?? []).map { entry in
                let child = path == "/" ? "/" + entry.name : path + "/" + entry.name
                return SFTPEntry(name: entry.name, kind: entry.kind, size: entry.size,
                                 mode: modes[child] ?? entry.mode, modified: times[child] ?? entry.modified,
                                 uid: owners[child]?.0 ?? entry.uid, gid: owners[child]?.1 ?? entry.gid,
                                 ownerName: entry.ownerName, groupName: entry.groupName)
            }
        }

        /// Run while a download is on its way, before its bytes are written.
        var duringDownload: ((String) async throws -> Void)?

        func download(_ path: String, to destination: URL) async throws {
            downloads.append(path)
            if let during = duringDownload {
                duringDownload = nil
                try await during(path)
            }
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

        /// Run once the server lists a file being sent, before the send ends.
        var duringUpload: ((String) async throws -> Void)?

        func upload(_ local: URL, to path: String) async throws {
            files[path] = try Data(contentsOf: local)
            link(path, .file)
            if let during = duringUpload {
                duringUpload = nil
                try await during(path)
            }
        }

        private(set) var modes: [String: UInt32] = [:]

        func setPermissions(_ path: String, mode: UInt32) async throws {
            modes[path] = mode
        }

        private(set) var owners: [String: (UInt32, UInt32)] = [:]

        func setOwnership(_ path: String, uid: UInt32, gid: UInt32) async throws {
            if refusesOwnership { throw CocoaError(.fileWriteNoPermission) }
            owners[path] = (uid, gid)
        }

        private(set) var times: [String: Date] = [:]

        func setTimes(_ path: String, modified: Date) async throws {
            times[path] = modified
        }

        /// The checksum commands this server has, and which were asked for.
        var hashCommands: Set<SFTPHashCommand> = []
        private(set) var hashAsked: [SFTPHashCommand] = []

        func sha256(of path: String, using command: SFTPHashCommand) async throws -> SFTPHashOutcome {
            hashAsked.append(command)
            guard hashCommands.contains(command) else { return .commandMissing }
            guard let data = files[path] else { return .failed }
            return .digest(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
        }

        /// Whether a change of owner is refused to the user, as a real server does.
        var refusesOwnership = false
        /// What sudo answers, in turn; and the commands and passwords it was given.
        var sudoAnswers: [SudoOutcome] = []
        private(set) var sudoCalls: [(arguments: [String], password: String?)] = []

        func runAsRoot(_ arguments: [String], password: String?) async throws -> SudoOutcome {
            sudoCalls.append((arguments, password))
            return sudoAnswers.isEmpty ? .done : sudoAnswers.removeFirst()
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

    /// Two files of one folder fetched at once, as before an archive is made of
    /// it: the one that finishes last kept the manifest as it was when it began,
    /// the other's bytes were off the record, and the next listing emptied them.
    func testFilesFetchedAtOnceAreAllKeptByTheNextListing() async throws {
        let server = FakeServer(folders: ["/d": [SFTPEntry(name: "a.txt", kind: .file, size: 5),
                                                 SFTPEntry(name: "b.txt", kind: .file, size: 3)]],
                                files: ["/d/a.txt": Data("hello".utf8), "/d/b.txt": Data("bye".utf8)])
        let shadow = mirror(server)
        try await shadow.populate("/d")
        server.duringDownload = { _ in _ = try await shadow.materialize("/d/b.txt") }

        let a = try await shadow.materialize("/d/a.txt")
        try await shadow.populate("/d")

        XCTAssertEqual(try String(contentsOf: a, encoding: .utf8), "hello")
        let b = a.deletingLastPathComponent().appendingPathComponent("b.txt")
        XCTAssertEqual(try String(contentsOf: b, encoding: .utf8), "bye")
        let recordedB = try await node(shadow, "/d/b.txt")
        XCTAssertEqual(recordedB?.backing, .file("b.txt"))
    }

    /// Parts Split wrote in a server's folder, sent one by one while the pane
    /// lists the folder: the part being sent, listed by the server already, was
    /// made a placeholder, and the rest were never sent. Once sent, the server's
    /// listing counts again: deleted there, it goes from here.
    func testAListingWhileAFileMadeHereIsSentLeavesItsBytes() async throws {
        let server = FakeServer(folders: ["/d": []])
        let shadow = mirror(server)
        try await shadow.populate("/d")
        let folder = await shadow.localURL(for: "/d")
        let part = folder.appendingPathComponent("big.dmg.002")
        try Data("two".utf8).write(to: part)
        let waiting = folder.appendingPathComponent("big.dmg.003")
        try Data("three".utf8).write(to: waiting)
        server.duringUpload = { _ in _ = try await shadow.populate("/d") }

        try await shadow.upload(part, to: "/d/big.dmg.002", isDirectory: false, keepingUpTo: .max)

        XCTAssertEqual(try String(contentsOf: part, encoding: .utf8), "two")
        XCTAssertEqual(try String(contentsOf: waiting, encoding: .utf8), "three")
        let sent = try await node(shadow, "/d/big.dmg.002")
        XCTAssertEqual(sent?.backing, .file("big.dmg.002"))
        // Waiting to be sent: nothing to fetch, and fetching is no error.
        let fetched = try await shadow.materialize("/d/big.dmg.003")
        XCTAssertEqual(fetched, waiting)

        try await server.removeFile("/d/big.dmg.002")
        try await shadow.populate("/d")
        XCTAssertFalse(FileManager.default.fileExists(atPath: part.path))
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

    /// An editor may have the file open: emptied and locked under it, it could
    /// not save. The bytes stay, and the next open fetches the server's again.
    func testAFileThatChangedOnTheServerKeepsItsBytesUntilOpenedAgain() async throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let server = FakeServer(folders: ["/d": [SFTPEntry(name: "a.txt", kind: .file, size: 5,
                                                           mode: 0o644, modified: date)]],
                                files: ["/d/a.txt": Data("hello".utf8)])
        let shadow = mirror(server)
        try await shadow.populate("/d")
        let file = try await shadow.materialize("/d/a.txt")

        server.folders["/d"] = [SFTPEntry(name: "a.txt", kind: .file, size: 9, mode: 0o644, modified: date)]
        server.files["/d/a.txt"] = Data("new there".utf8)
        try await shadow.populate("/d")
        XCTAssertEqual(try Data(contentsOf: file), Data("hello".utf8))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int, 0o600)
        let marked = try await node(shadow, "/d/a.txt")
        XCTAssertTrue(SFTPMirror.needsFetch(marked, at: file))
        // Still marked after a second listing, which reports what the first did.
        try await shadow.populate("/d")
        let stillMarked = try await node(shadow, "/d/a.txt")
        XCTAssertTrue(SFTPMirror.needsFetch(stillMarked, at: file))

        _ = try await shadow.materialize("/d/a.txt")
        XCTAssertEqual(try Data(contentsOf: file), Data("new there".utf8))
        let fetched = try await node(shadow, "/d/a.txt")
        XCTAssertFalse(SFTPMirror.needsFetch(fetched, at: file))
    }

    /// The case of an editor that had the file open while the server changed it,
    /// and a listing came in between: the save is a conflict, not sent.
    func testASaveAfterAListingOfAServerChangeIsStillAConflict() async throws {
        let (server, shadow) = try await editable()
        server.folders["/d"] = [SFTPEntry(name: "a.txt", kind: .file, size: 13, mode: 0o644)]
        server.files["/d/a.txt"] = Data("changed there".utf8)
        try await shadow.populate("/d")
        _ = try await edit(shadow, "/d/a.txt", to: "edited here")

        guard case .conflict = try await shadow.writeBack("/d/a.txt") else {
            return XCTFail("not seen as a conflict")
        }
        XCTAssertEqual(server.files["/d/a.txt"], Data("changed there".utf8))
        // Edited here: opening it again keeps the edit rather than fetching over it.
        let file = await shadow.localURL(for: "/d/a.txt")
        let edited = try await node(shadow, "/d/a.txt")
        XCTAssertFalse(SFTPMirror.needsFetch(edited, at: file))
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

    // MARK: - Editing here, sending back

    /// A fetched file, and the copy here edited: its time moved on, so that it
    /// reads as changed whatever the clock's resolution.
    private func edit(_ shadow: SFTPMirror, _ path: String, to text: String) async throws -> URL {
        let file = await shadow.localURL(for: path)
        try Data(text.utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(10)],
                                              ofItemAtPath: file.path)
        return file
    }

    private func editable() async throws -> (FakeServer, SFTPMirror) {
        let server = FakeServer(folders: ["/d": [SFTPEntry(name: "a.txt", kind: .file, size: 5, mode: 0o644)]],
                                files: ["/d/a.txt": Data("hello".utf8)])
        let shadow = mirror(server)
        try await shadow.populate("/d")
        _ = try await shadow.materialize("/d/a.txt")
        return (server, shadow)
    }

    func testAFetchedFileIsWritableHereOnlyWhenTheServerLetsItsOwnerWrite() async throws {
        let server = FakeServer(folders: ["/d": [SFTPEntry(name: "w.txt", kind: .file, size: 1, mode: 0o644),
                                                 SFTPEntry(name: "r.txt", kind: .file, size: 1, mode: 0o444)]],
                                files: ["/d/w.txt": Data("w".utf8), "/d/r.txt": Data("r".utf8)])
        let shadow = mirror(server)
        try await shadow.populate("/d")
        let writable = try await shadow.materialize("/d/w.txt")
        let readable = try await shadow.materialize("/d/r.txt")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: writable.path)[.posixPermissions] as? Int, 0o600)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: readable.path)[.posixPermissions] as? Int, 0o400)
    }

    func testASavedEditIsSentWhenTheServersCopyIsUnchanged() async throws {
        let (server, shadow) = try await editable()
        let unchanged = try await shadow.writeBack("/d/a.txt")
        XCTAssertEqual(unchanged, .unchanged)

        _ = try await edit(shadow, "/d/a.txt", to: "edited here")
        let sent = try await shadow.writeBack("/d/a.txt")
        XCTAssertEqual(sent, .sent)
        XCTAssertEqual(server.files["/d/a.txt"], Data("edited here".utf8))
        let again = try await shadow.writeBack("/d/a.txt")
        XCTAssertEqual(again, .unchanged)
    }

    func testAnEditOverAServerChangeIsAConflictNotSent() async throws {
        let (server, shadow) = try await editable()
        server.files["/d/a.txt"] = Data("changed there".utf8)
        _ = try await edit(shadow, "/d/a.txt", to: "edited here")

        guard case .conflict(let copy, _, let isText) = try await shadow.writeBack("/d/a.txt") else {
            return XCTFail("not seen as a conflict")
        }
        XCTAssertTrue(isText)
        XCTAssertEqual(try Data(contentsOf: copy), Data("changed there".utf8))
        XCTAssertEqual(server.files["/d/a.txt"], Data("changed there".utf8))
    }

    func testABinaryConflictIsSaidToBeBinary() async throws {
        let (server, shadow) = try await editable()
        server.files["/d/a.txt"] = Data([0, 1, 2])
        _ = try await edit(shadow, "/d/a.txt", to: "edited here")
        guard case .conflict(_, _, let isText) = try await shadow.writeBack("/d/a.txt") else {
            return XCTFail("not seen as a conflict")
        }
        XCTAssertFalse(isText)
    }

    func testEachWayOfSettlingAConflictDoesWhatItSays() async throws {
        // Over the server's: its version becomes the baseline, and the edit is sent.
        var (server, shadow) = try await editable()
        server.files["/d/a.txt"] = Data("changed there".utf8)
        _ = try await edit(shadow, "/d/a.txt", to: "mine")
        guard case .conflict(_, let theirs, _) = try await shadow.writeBack("/d/a.txt") else { return XCTFail() }
        try await shadow.adoptBaseline("/d/a.txt", checksum: theirs)
        let sent = try await shadow.writeBack("/d/a.txt")
        XCTAssertEqual(sent, .sent)
        XCTAssertEqual(server.files["/d/a.txt"], Data("mine".utf8))

        // The server's kept: the copy here is the server's again, and unchanged.
        (server, shadow) = try await editable()
        server.files["/d/a.txt"] = Data("changed there".utf8)
        let file = try await edit(shadow, "/d/a.txt", to: "mine")
        guard case .conflict(let copy, let checksum, _) = try await shadow.writeBack("/d/a.txt") else { return XCTFail() }
        try await shadow.keepServersVersion("/d/a.txt", from: copy, checksum: checksum)
        XCTAssertEqual(try Data(contentsOf: file), Data("changed there".utf8))
        let settled = try await shadow.writeBack("/d/a.txt")
        XCTAssertEqual(settled, .unchanged)

        // Under a new name: the edit goes beside the server's file, which stays.
        (server, shadow) = try await editable()
        server.files["/d/a.txt"] = Data("changed there".utf8)
        _ = try await edit(shadow, "/d/a.txt", to: "mine")
        let name = try await shadow.sendAsNew("/d/a.txt")
        XCTAssertEqual(name, "a-1.txt")
        XCTAssertEqual(server.files["/d/a-1.txt"], Data("mine".utf8))
        XCTAssertEqual(server.files["/d/a.txt"], Data("changed there".utf8))
    }

    func testAListingNeverLosesAnEditNotYetSent() async throws {
        let (server, shadow) = try await editable()
        let file = try await edit(shadow, "/d/a.txt", to: "edited here")
        // The server's file changed size, and then went altogether.
        server.folders["/d"] = [SFTPEntry(name: "a.txt", kind: .file, size: 99, mode: 0o644)]
        try await shadow.populate("/d")
        XCTAssertEqual(try Data(contentsOf: file), Data("edited here".utf8))
        server.folders["/d"] = []
        try await shadow.populate("/d")
        XCTAssertEqual(try Data(contentsOf: file), Data("edited here".utf8))
    }

    /// An editor saving while the server is listing the folder: the save must
    /// still be seen as an edit, and sent.
    func testASaveMadeWhileTheServerListsIsStillSent() async throws {
        let (server, shadow) = try await editable()
        let file = await shadow.localURL(for: "/d/a.txt")
        server.duringListing = {
            try? Data("saved meanwhile".utf8).write(to: file)
            try? FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(10)],
                                                   ofItemAtPath: file.path)
        }
        try await shadow.populate("/d")
        let sent = try await shadow.writeBack("/d/a.txt")
        XCTAssertEqual(sent, .sent)
        XCTAssertEqual(server.files["/d/a.txt"], Data("saved meanwhile".utf8))
    }

    /// An editor's own file beside the one it saves is not the server's to take away.
    func testAListingLeavesAFileOfAnEditorsOwnAlone() async throws {
        let (_, shadow) = try await editable()
        let folder = await shadow.localURL(for: "/d")
        let temporary = folder.appendingPathComponent(".a.txt.sb-1234")
        try Data("half a save".utf8).write(to: temporary)
        try await shadow.populate("/d")
        XCTAssertTrue(FileManager.default.fileExists(atPath: temporary.path))
    }

    /// The bytes decide, not the time: an edit whose time looks like the fetch's
    /// is still an edit.
    func testAnEditIsSentEvenWhenItsTimeIsTheFetchedOnes() async throws {
        let (server, shadow) = try await editable()
        let file = await shadow.localURL(for: "/d/a.txt")
        let fetchedAt = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date
        try Data("same time".utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: fetchedAt!], ofItemAtPath: file.path)
        let sent = try await shadow.writeBack("/d/a.txt")
        XCTAssertEqual(sent, .sent)
        XCTAssertEqual(server.files["/d/a.txt"], Data("same time".utf8))
    }

    /// A file a Diptych editor holds unsaved changes to is never fetched again.
    func testAFileHeldByAnEditorIsNotFetchedAgain() async throws {
        let (server, shadow) = try await editable()
        server.folders["/d"] = [SFTPEntry(name: "a.txt", kind: .file, size: 9, mode: 0o644)]
        try await shadow.populate("/d")
        let file = await shadow.localURL(for: "/d/a.txt")
        let changedThere = try await node(shadow, "/d/a.txt")
        XCTAssertTrue(SFTPMirror.needsFetch(changedThere, at: file))
        EditedHere.hold(file)
        defer { EditedHere.release(file) }
        XCTAssertFalse(SFTPMirror.needsFetch(changedThere, at: file))
    }

    /// Sent as a new file, the edit is kept here as well: the server and the copy
    /// here are the same, and listing the folder again leaves it so.
    func testAFileSentAsNewIsKeptHereAsFetched() async throws {
        let (server, shadow) = try await editable()
        server.files["/d/a.txt"] = Data("changed there".utf8)
        _ = try await edit(shadow, "/d/a.txt", to: "mine")
        let name = try await shadow.sendAsNew("/d/a.txt")
        try await shadow.populate("/d")
        let sent = await shadow.localURL(for: "/d/" + name)
        let kept = try await node(shadow, "/d/" + name)
        XCTAssertEqual(kept?.backing, .file(name))
        XCTAssertEqual(try Data(contentsOf: sent), Data("mine".utf8))
        XCTAssertFalse(SFTPMirror.needsFetch(kept, at: sent))
        XCTAssertEqual(kept?.attribute(BrowserManifest.Attribute.checksum)?.stringValue,
                       try FileChecksum.sha256(of: sent))
    }

    /// A copy to the server is kept here when it is no bigger than the limit.
    func testAnUploadIsKeptHereOnlyWithinTheLimit() async throws {
        let (_, shadow) = try await editable()
        let local = FileManager.default.temporaryDirectory
            .appendingPathComponent("upload-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        let small = local.appendingPathComponent("small.txt")
        let big = local.appendingPathComponent("big.txt")
        try Data("tiny".utf8).write(to: small)
        try Data(repeating: 7, count: 100).write(to: big)
        try await shadow.upload(small, to: "/d/small.txt", isDirectory: false, keepingUpTo: 10)
        try await shadow.upload(big, to: "/d/big.txt", isDirectory: false, keepingUpTo: 10)
        try await shadow.populate("/d")
        let smallNode = try await node(shadow, "/d/small.txt")
        let bigNode = try await node(shadow, "/d/big.txt")
        XCTAssertEqual(smallNode?.backing, .file("small.txt"))
        XCTAssertEqual(bigNode?.backing, BrowserManifest.Backing.none)
    }

    func testAFreeNameCountsUpBeforeTheExtension() {
        XCTAssertEqual(SFTPMirror.freeName(for: "a.txt", among: ["a-1.txt"]), "a-2.txt")
        XCTAssertEqual(SFTPMirror.freeName(for: "Makefile", among: []), "Makefile-1")
    }

    // MARK: - A checksum on the server instead of fetching again

    /// What a mirror learnt about the server's checksum command.
    final class Learnt: @unchecked Sendable {
        private let lock = NSLock()
        private var said: [SFTPHashSupport] = []
        func add(_ support: SFTPHashSupport) { lock.withLock { said.append(support) } }
        var all: [SFTPHashSupport] { lock.withLock { said } }
    }

    /// A fetched file the server now lists with a new date: changed there, as far
    /// as the listing can tell.
    private func touchedOnServer(_ server: FakeServer, hashing: SFTPHashSupport = .untried,
                                 learnt: Learnt = Learnt()) async throws -> SFTPMirror {
        let shadow = SFTPMirror(
            root: FileManager.default.temporaryDirectory.appendingPathComponent("sftp-mirror-\(UUID().uuidString)"),
            remote: server, host: "nas", hashing: hashing, learned: { learnt.add($0) })
        try await shadow.populate("/d")
        _ = try await shadow.materialize("/d/a.txt")
        try await server.setTimes("/d/a.txt", modified: Date(timeIntervalSince1970: 1_700_000_000))
        try await shadow.populate("/d")
        let flagged = try await node(shadow, "/d/a.txt")
        XCTAssertEqual(flagged?.attribute(BrowserManifest.Attribute.serverChanged)?.boolValue, true)
        return shadow
    }

    private func serverWithAFile() -> FakeServer {
        FakeServer(folders: ["/d": [SFTPEntry(name: "a.txt", kind: .file, size: 5,
                                              modified: Date(timeIntervalSince1970: 1_600_000_000))]],
                   files: ["/d/a.txt": Data("hello".utf8)])
    }

    func testTheSameBytesOnTheServerAreNotFetchedAgain() async throws {
        let server = serverWithAFile()
        server.hashCommands = [.shasum]
        let learnt = Learnt()
        let shadow = try await touchedOnServer(server, learnt: learnt)

        let file = try await shadow.materialize("/d/a.txt", checkingUpTo: 1_000)

        XCTAssertEqual(server.downloads, ["/d/a.txt"], "fetched again")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "hello")
        let checked = try await node(shadow, "/d/a.txt")
        XCTAssertNil(checked?.attribute(BrowserManifest.Attribute.serverChanged))
        // sha256sum first, which this server lacks, then shasum, which it has.
        XCTAssertEqual(server.hashAsked, [.sha256sum, .shasum])
        XCTAssertEqual(learnt.all, [.works(.shasum)])
    }

    func testOtherBytesOfTheSameSizeAreFetched() async throws {
        let server = serverWithAFile()
        server.hashCommands = [.sha256sum]
        let shadow = try await touchedOnServer(server)
        server.files["/d/a.txt"] = Data("HELLO".utf8)

        let file = try await shadow.materialize("/d/a.txt", checkingUpTo: 1_000)

        XCTAssertEqual(server.downloads, ["/d/a.txt", "/d/a.txt"])
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "HELLO")
    }

    func testAFileOverTheLimitIsFetchedWithoutAsking() async throws {
        let server = serverWithAFile()
        server.hashCommands = [.sha256sum]
        let shadow = try await touchedOnServer(server)

        _ = try await shadow.materialize("/d/a.txt", checkingUpTo: 4)

        XCTAssertEqual(server.downloads.count, 2)
        XCTAssertEqual(server.hashAsked, [])
    }

    /// A server with neither command is asked once; after that it is known, and
    /// the file is simply fetched.
    func testAServerWithNoChecksumCommandIsNotAskedAgain() async throws {
        let server = serverWithAFile()
        let learnt = Learnt()
        let shadow = try await touchedOnServer(server, learnt: learnt)

        _ = try await shadow.materialize("/d/a.txt", checkingUpTo: 1_000)
        XCTAssertEqual(learnt.all, [SFTPHashSupport.none])
        XCTAssertEqual(server.hashAsked.count, 2)

        try await server.setTimes("/d/a.txt", modified: Date(timeIntervalSince1970: 1_800_000_000))
        try await shadow.populate("/d")
        _ = try await shadow.materialize("/d/a.txt", checkingUpTo: 1_000)
        XCTAssertEqual(server.hashAsked.count, 2)
        XCTAssertEqual(server.downloads.count, 3)
    }

    func testWhatIsKeptAboutChecksumsReadsBack() {
        for support in [SFTPHashSupport.untried, .none, .works(.sha256sum), .works(.shasum)] {
            XCTAssertEqual(SFTPHashSupport(stored: support.stored), support)
        }
        XCTAssertEqual(SFTPHashCommand.digest(in: String(repeating: "Ab", count: 32) + "  /d/a.txt\n"),
                       String(repeating: "ab", count: 32))
        XCTAssertNil(SFTPHashCommand.digest(in: "sha256sum: a.txt: No such file\n"))
        XCTAssertEqual(SFTPHashCommand.sha256sum.line(for: "/d/it's.txt"),
                       "sha256sum -- '/d/it'\\''s.txt'")
    }
}
