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

    func testDeletingAFolderDeletesWhatIsInIt() async throws {
        let connected = try await connect()
        let home = RemoteBrowsing.localURL(on: connected, remote: "/home")
        try await RemoteBrowsing.refresh(home)
        let peter = RemoteBrowsing.localURL(on: connected, remote: "/home/peter")

        try await RemoteBrowsing.remove([peter])
        XCTAssertNil(server.folders["/home/peter"])
        XCTAssertNil(server.files["/home/peter/note.txt"])
    }
}
