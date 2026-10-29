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
}
