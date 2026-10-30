import XCTest
@testable import Diptych

/// The mapping between a server's shadow folders and their sftp:// addresses,
/// and what is fetched before a file is used, against a fake server.
final class RemoteBrowsingTests: XCTestCase {

    private var server: SFTPMirrorTests.FakeServer!

    override func setUp() {
        super.setUp()
        RemoteBrowsing.cacheRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-browsing-\(UUID().uuidString)")
        server = SFTPMirrorTests.FakeServer(
            folders: ["/": [SFTPEntry(name: "home", kind: .directory)],
                      "/home": [SFTPEntry(name: "peter", kind: .directory)],
                      "/home/peter": [SFTPEntry(name: "note.txt", kind: .file, size: 5)]],
            files: ["/home/peter/note.txt": Data("hello".utf8)])
    }

    override func tearDown() {
        RemoteBrowsing.removeAll()
        super.tearDown()
    }

    /// Connects the fake server as `peter@nas`, the way a connection does.
    private func connect() async throws -> RemoteBrowsing.Server {
        let root = RemoteBrowsing.shadowRoot(user: "peter", host: "nas", port: 22)
        let mirror = SFTPMirror(root: root, remote: server, host: "nas")
        let connected = RemoteBrowsing.Server(user: "peter", host: "nas", port: 22, root: root,
                                              mirror: mirror, close: {})
        RemoteBrowsing.add(connected)
        try await mirror.populate("/")
        return connected
    }

    func testAShadowFolderIsShownByItsAddressAndFoundAgain() async throws {
        let connected = try await connect()
        let local = RemoteBrowsing.localURL(on: connected, remote: "/home/peter")
        XCTAssertTrue(RemoteBrowsing.isInside(local))
        XCTAssertEqual(RemoteBrowsing.shown(local)?.absoluteString, "sftp://peter@nas/home/peter")

        let address = URL(string: "sftp://peter@nas/home/peter")!
        XCTAssertEqual(RemoteBrowsing.actual(address)?.standardizedFileURL.path,
                       local.standardizedFileURL.path)
        XCTAssertNil(RemoteBrowsing.actual(URL(string: "sftp://someone@nas/home/peter")!))
    }

    func testTheTopOfAServerIsItsRootAndNothingLiesAboveIt() async throws {
        let connected = try await connect()
        XCTAssertTrue(RemoteBrowsing.isServerRoot(connected.root))
        XCTAssertFalse(RemoteBrowsing.isServerRoot(RemoteBrowsing.localURL(on: connected, remote: "/home")))
    }

    func testAServerFolderIsANetworkVolumeThatIsReadOnly() async throws {
        let connected = try await connect()
        let facts = RemoteBrowsing.volumeFacts(of: RemoteBrowsing.localURL(on: connected, remote: "/home"))
        XCTAssertEqual(facts?.isNetwork, true)
        XCTAssertEqual(facts?.isReadOnly, true)
        XCTAssertEqual(facts?.name, "nas")
    }

    func testAFileIsPendingUntilItsBytesAreFetched() async throws {
        let connected = try await connect()
        let file = RemoteBrowsing.localURL(on: connected, remote: "/home/peter/note.txt")
        try await RemoteBrowsing.refresh(RemoteBrowsing.localURL(on: connected, remote: "/home/peter"))
        XCTAssertTrue(RemoteBrowsing.hasPending([file]))

        try await RemoteBrowsing.materialize(file)
        XCTAssertFalse(RemoteBrowsing.hasPending([file]))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "hello")
    }

    func testFetchingAFolderFetchesEveryFileBelowIt() async throws {
        let connected = try await connect()
        let home = RemoteBrowsing.localURL(on: connected, remote: "/home")
        XCTAssertTrue(RemoteBrowsing.hasPending([home]))

        try await RemoteBrowsing.fetch([home])
        XCTAssertFalse(RemoteBrowsing.hasPending([home]))
        let file = RemoteBrowsing.localURL(on: connected, remote: "/home/peter/note.txt")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "hello")
    }

    func testAPathThatIsNotOnAServerIsNotPending() {
        XCTAssertFalse(RemoteBrowsing.hasPending([URL(fileURLWithPath: "/tmp")]))
        XCTAssertNil(RemoteBrowsing.shown(URL(fileURLWithPath: "/tmp")))
    }

    func testAConnectedServerIsAnEjectableNetworkVolumeNamedAfterItsHost() async throws {
        let connected = try await connect()
        let entries = RemoteBrowsing.sidebarEntries()
        XCTAssertEqual(entries.map(\.name), ["nas"])
        XCTAssertEqual(entries.first?.url.path, connected.root.path)
        XCTAssertEqual(entries.first?.isEjectable, true)
        XCTAssertEqual(entries.first?.isNetwork, true)
    }

    func testDisconnectingRemovesTheServerAndItsShadow() async throws {
        let connected = try await connect()
        try await RemoteBrowsing.refresh(RemoteBrowsing.localURL(on: connected, remote: "/home"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: connected.root.path))

        XCTAssertTrue(RemoteBrowsing.disconnect(root: connected.root))
        XCTAssertTrue(RemoteBrowsing.sidebarEntries().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: connected.root.path))
        XCTAssertFalse(RemoteBrowsing.disconnect(root: connected.root))
    }

    // MARK: - Changes made on the server

    func testANewFolderIsMadeOnTheServerAndListed() async throws {
        let connected = try await connect()
        let home = RemoteBrowsing.localURL(on: connected, remote: "/home/peter")
        let made = try await RemoteBrowsing.makeFolder(named: "photos", in: home)

        XCTAssertEqual(server.folders["/home/peter/photos"], [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: made.path))
        XCTAssertEqual(made.standardizedFileURL.path,
                       RemoteBrowsing.localURL(on: connected, remote: "/home/peter/photos").standardizedFileURL.path)
    }

    func testAFileIsUploadedAndAnExistingNameIsNotWrittenOver() async throws {
        let connected = try await connect()
        let home = RemoteBrowsing.localURL(on: connected, remote: "/home/peter")
        let local = FileManager.default.temporaryDirectory
            .appendingPathComponent("upload-\(UUID().uuidString).txt")
        try Data("new".utf8).write(to: local)

        try await RemoteBrowsing.upload([local], into: home)
        XCTAssertEqual(server.files["/home/peter/" + local.lastPathComponent], Data("new".utf8))

        do {
            try await RemoteBrowsing.upload([local], into: home)
            XCTFail("written over")
        } catch {
            XCTAssertEqual(error as? RemoteWriteError, .exists(local.lastPathComponent))
        }
    }

    func testAFolderIsUploadedWithEverythingInIt() async throws {
        let connected = try await connect()
        let home = RemoteBrowsing.localURL(on: connected, remote: "/home/peter")
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("tree-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("sub"),
                                                withIntermediateDirectories: true)
        try Data("a".utf8).write(to: folder.appendingPathComponent("sub/a.txt"))

        try await RemoteBrowsing.upload([folder], into: home)
        let name = folder.lastPathComponent
        XCTAssertEqual(server.files["/home/peter/\(name)/sub/a.txt"], Data("a".utf8))
    }

    func testRenameAndDeleteAreMadeOnTheServer() async throws {
        let connected = try await connect()
        let home = RemoteBrowsing.localURL(on: connected, remote: "/home/peter")
        try await RemoteBrowsing.refresh(home)
        let note = RemoteBrowsing.localURL(on: connected, remote: "/home/peter/note.txt")

        let renamed = try await RemoteBrowsing.rename(note, to: "memo.txt")
        XCTAssertNil(server.files["/home/peter/note.txt"])
        XCTAssertEqual(server.files["/home/peter/memo.txt"], Data("hello".utf8))
        XCTAssertEqual(renamed.lastPathComponent, "memo.txt")

        try await RemoteBrowsing.remove([renamed])
        XCTAssertNil(server.files["/home/peter/memo.txt"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: renamed.path))
    }

    func testPermissionsAreSetOnTheServerAndTheListingShowsThem() async throws {
        let connected = try await connect()
        let home = RemoteBrowsing.localURL(on: connected, remote: "/home/peter")
        try await RemoteBrowsing.refresh(home)
        let note = RemoteBrowsing.localURL(on: connected, remote: "/home/peter/note.txt")

        try await RemoteBrowsing.setPermissions(0o600, for: [note])
        XCTAssertEqual(server.modes["/home/peter/note.txt"], 0o600)
        let shown = try await node(connected, "/home/peter/note.txt")
        XCTAssertEqual(shown?.attribute(BrowserManifest.Attribute.mode)?.intValue, 0o600)
    }

    private func node(_ server: RemoteBrowsing.Server, _ path: String) async throws -> BrowserManifest.Node? {
        let folder = RemoteBrowsing.localURL(on: server, remote: (path as NSString).deletingLastPathComponent)
        return BrowserManifestStore.read(in: folder)?.nodes.first { $0.name == (path as NSString).lastPathComponent }
    }

    func testDeletingAFolderDeletesWhatIsInIt() async throws {
        let connected = try await connect()
        let home = RemoteBrowsing.localURL(on: connected, remote: "/home")
        try await RemoteBrowsing.refresh(home)
        let peter = RemoteBrowsing.localURL(on: connected, remote: "/home/peter")

        try await RemoteBrowsing.remove([peter])
        XCTAssertNil(server.folders["/home/peter"])
        XCTAssertNil(server.files["/home/peter/note.txt"])
    }

    /// A placeholder's own size is zero, so the size is the server's listing: and
    /// a listing without one leaves the size unknown, never zero.
    func testAPlaceholderHasTheSizeTheServerListedOrNoneAtAll() async throws {
        server.folders["/home/peter"] = [SFTPEntry(name: "note.txt", kind: .file, size: 5),
                                         SFTPEntry(name: "unknown.bin", kind: .file)]
        let connected = try await connect()
        let folder = RemoteBrowsing.localURL(on: connected, remote: "/home/peter")
        try await RemoteBrowsing.refresh(folder)

        XCTAssertEqual(RemoteBrowsing.placeholder(folder.appendingPathComponent("note.txt"))?.size, 5)
        let unknown = RemoteBrowsing.placeholder(folder.appendingPathComponent("unknown.bin"))
        XCTAssertNotNil(unknown)
        XCTAssertNil(unknown?.size)
    }

    /// What the MCP tools report: the address of a server's folder, which is
    /// where it is, and not the cache it is read from.
    func testAServerFolderIsReportedByItsAddressAndALocalOneByItsPath() async throws {
        let connected = try await connect()
        let home = RemoteBrowsing.localURL(on: connected, remote: "/home/peter")
        XCTAssertEqual(RemoteBrowsing.reportedPath(home), "sftp://peter@nas/home/peter")
        XCTAssertEqual(RemoteBrowsing.reportedPath(URL(fileURLWithPath: "/tmp/x")), "/tmp/x")
    }

    /// A server's own absolute path finds the copy kept for it, once it is listed.
    func testAServerPathFindsItsListedCopy() async throws {
        let connected = try await connect()
        XCTAssertTrue(RemoteBrowsing.shadows(ofRemotePath: "/home/peter").isEmpty)
        try await RemoteBrowsing.refresh(RemoteBrowsing.localURL(on: connected, remote: "/home/peter"))
        let found = RemoteBrowsing.shadows(ofRemotePath: "/home/peter")
        XCTAssertEqual(found.map { $0.standardizedFileURL.path },
                       [RemoteBrowsing.localURL(on: connected, remote: "/home/peter").standardizedFileURL.path])
    }

    // MARK: - Files, times and owners

    func testAnEmptyFileIsCreatedOnTheServer() async throws {
        let connected = try await connect()
        let home = RemoteBrowsing.localURL(on: connected, remote: "/home/peter")
        try await RemoteBrowsing.refresh(home)
        _ = try await RemoteBrowsing.createFile(named: "new.txt", in: home)
        XCTAssertEqual(server.files["/home/peter/new.txt"], Data())
    }

    func testTheModificationTimeIsSetOnTheServer() async throws {
        let connected = try await connect()
        try await RemoteBrowsing.refresh(RemoteBrowsing.localURL(on: connected, remote: "/home/peter"))
        let note = RemoteBrowsing.localURL(on: connected, remote: "/home/peter/note.txt")
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        try await RemoteBrowsing.setTimes(modified: when, for: [note])
        XCTAssertEqual(server.times["/home/peter/note.txt"], when)
    }

    /// The server's names, from its own listing: a name only the server has is
    /// set by its number there, and a name it does not show is refused.
    func testTheOwnerIsSetByTheServersOwnNameOrByNumber() async throws {
        server.folders["/home/peter"] = [
            SFTPEntry(name: "note.txt", kind: .file, size: 5, uid: 1000, gid: 1000,
                      ownerName: "verhas", groupName: "verhas"),
            SFTPEntry(name: "web.txt", kind: .file, size: 1, uid: 33, gid: 33,
                      ownerName: "www-data", groupName: "www-data"),
        ]
        let connected = try await connect()
        let folder = RemoteBrowsing.localURL(on: connected, remote: "/home/peter")
        try await RemoteBrowsing.refresh(folder)
        let note = folder.appendingPathComponent("note.txt")

        XCTAssertEqual(RemoteBrowsing.accounts(of: connected).users["www-data"], 33)
        XCTAssertTrue(RemoteBrowsing.knowsAccount("www-data", group: false, for: note))
        XCTAssertTrue(RemoteBrowsing.knowsAccount("4242", group: true, for: note))
        XCTAssertFalse(RemoteBrowsing.knowsAccount("nobody-here", group: false, for: note))

        try await RemoteBrowsing.setOwnership(owner: "www-data", group: nil, for: [note])
        XCTAssertEqual(server.owners["/home/peter/note.txt"]?.0, 33)
        XCTAssertEqual(server.owners["/home/peter/note.txt"]?.1, 1000)

        do {
            try await RemoteBrowsing.setOwnership(owner: "nobody-here", group: nil, for: [note])
            XCTFail("an unknown name was taken")
        } catch {
            XCTAssertEqual(error as? RemoteWriteError, .unknownAccount("nobody-here"))
        }
    }

    func testAFileIsCreatedOnTheServerWithItsContent() async throws {
        let connected = try await connect()
        let home = RemoteBrowsing.localURL(on: connected, remote: "/home/peter")
        try await RemoteBrowsing.refresh(home)
        _ = try await RemoteBrowsing.createFile(named: "hello.txt", in: home, contents: Data("hi".utf8))
        XCTAssertEqual(server.files["/home/peter/hello.txt"], Data("hi".utf8))
    }

    func testAFileIsUploadedUnderTheNameItIsGiven() async throws {
        let connected = try await connect()
        let home = RemoteBrowsing.localURL(on: connected, remote: "/home/peter")
        try await RemoteBrowsing.refresh(home)
        let local = FileManager.default.temporaryDirectory.appendingPathComponent("up-\(UUID().uuidString)")
        try Data("x".utf8).write(to: local)
        try await RemoteBrowsing.upload(local, as: home.appendingPathComponent("renamed.txt"))
        XCTAssertEqual(server.files["/home/peter/renamed.txt"], Data("x".utf8))
    }

    func testTheListedModeIsTheServersNotTheLockedCopys() async throws {
        server.folders["/home/peter"] = [SFTPEntry(name: "note.txt", kind: .file, size: 5, mode: 0o644)]
        let connected = try await connect()
        let folder = RemoteBrowsing.localURL(on: connected, remote: "/home/peter")
        try await RemoteBrowsing.refresh(folder)
        XCTAssertEqual(RemoteBrowsing.listedMode(of: folder.appendingPathComponent("note.txt")), 0o644)
    }

    // MARK: - Through sudo

    /// A server that refuses the change to the user gets it through sudo: first
    /// with no password, then with the one the person gives, kept as chosen.
    func testARefusedOwnerChangeIsMadeThroughSudoWithThePasswordGiven() async throws {
        server.folders["/home/peter"] = [SFTPEntry(name: "note.txt", kind: .file, size: 5,
                                                   uid: 1000, gid: 1000, ownerName: "peter")]
        server.refusesOwnership = true
        server.sudoAnswers = [.needsPassword, .done]
        let connected = try await connect()
        let folder = RemoteBrowsing.localURL(on: connected, remote: "/home/peter")
        try await RemoteBrowsing.refresh(folder)
        RemoteBrowsing.askForSudo = { _, _, _ in SudoAnswer(password: "secret", keep: .fiveMinutes) }
        defer { RemoteBrowsing.askForSudo = { host, user, wrong in
            await SudoPrompter.ask(host: host, user: user, wasWrong: wrong) } }

        try await RemoteBrowsing.setOwnership(owner: "0", group: nil, for: [folder.appendingPathComponent("note.txt")])

        XCTAssertEqual(server.sudoCalls.map(\.password), [nil, "secret"])
        XCTAssertEqual(server.sudoCalls.last?.arguments, ["chown", "0:1000", "--", "/home/peter/note.txt"])
        XCTAssertEqual(SudoPasswords.shared.password(for: connected.key), "secret")

        RemoteBrowsing.disconnect(root: connected.root)
        XCTAssertNil(SudoPasswords.shared.password(for: connected.key))
    }

    func testAUserNotAllowedToUseSudoIsToldSo() async throws {
        server.folders["/home/peter"] = [SFTPEntry(name: "note.txt", kind: .file, size: 5, uid: 1000, gid: 1000)]
        server.refusesOwnership = true
        server.sudoAnswers = [.notAllowed("peter is not in the sudoers file.")]
        let connected = try await connect()
        let folder = RemoteBrowsing.localURL(on: connected, remote: "/home/peter")
        try await RemoteBrowsing.refresh(folder)
        do {
            try await RemoteBrowsing.setOwnership(owner: "0", group: nil, for: [folder.appendingPathComponent("note.txt")])
            XCTFail("done without sudo rights")
        } catch {
            XCTAssertEqual(error as? RemoteWriteError, .sudoRefused("peter is not in the sudoers file."))
        }
    }

    func testAnEditNotYetSentIsCountedAsUnsent() async throws {
        server.folders["/home/peter"] = [SFTPEntry(name: "note.txt", kind: .file, size: 5, mode: 0o644)]
        let connected = try await connect()
        let folder = RemoteBrowsing.localURL(on: connected, remote: "/home/peter")
        try await RemoteBrowsing.refresh(folder)
        let note = folder.appendingPathComponent("note.txt")
        try await RemoteBrowsing.materialize(note)
        XCTAssertTrue(RemoteBrowsing.unsentEdits(under: connected.root).isEmpty)

        try Data("changed".utf8).write(to: note)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(10)],
                                              ofItemAtPath: note.path)
        XCTAssertEqual(RemoteBrowsing.unsentEdits(under: connected.root).map(\.lastPathComponent), ["note.txt"])
    }

    /// The Info window shows a server file as the server has it: its mode and its
    /// owner, never the copy kept here or a user of this Mac.
    func testTheInfoWindowShowsTheServersFactsNotTheCopys() async throws {
        server.folders["/home/peter"] = [SFTPEntry(name: "note.txt", kind: .file, size: 5, mode: 0o640,
                                                   uid: 33, gid: 33, ownerName: "www-data", groupName: "www-data")]
        let connected = try await connect()
        let folder = RemoteBrowsing.localURL(on: connected, remote: "/home/peter")
        try await RemoteBrowsing.refresh(folder)

        let file = folder.appendingPathComponent("note.txt")
        let shown = await MainActor.run { () -> (onServer: Bool, mode: mode_t, owner: String, group: String) in
            let info = FileInfoModel(url: file)
            return (info.isOnServer, info.mode, info.owner, info.group)
        }
        XCTAssertTrue(shown.onServer)
        XCTAssertEqual(shown.mode & 0o7777, 0o640)
        XCTAssertEqual(shown.owner, "www-data")
        XCTAssertEqual(shown.group, "www-data")
        XCTAssertEqual(RemoteBrowsing.accountNames(for: folder).users, ["www-data"])
    }
}
