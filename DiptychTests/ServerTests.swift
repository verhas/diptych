import XCTest
@testable import Diptych

/// Connect to Server: what an address means, which mounted volume is the
/// one asked for, and the servers kept between runs. Nothing here needs a
/// server.
@MainActor
final class ServerTests: XCTestCase {

    private func parse(_ text: String) -> URL? {
        try? ServerAddress.parse(text).get()
    }

    private func problem(_ text: String) -> String? {
        if case .failure(let problem) = ServerAddress.parse(text) { return problem.message }
        return nil
    }

    // MARK: - Addresses

    func testABareNameIsAnSMBServer() {
        XCTAssertEqual(parse("nas.local")?.absoluteString, "smb://nas.local")
        XCTAssertEqual(parse("  nas/photos ")?.absoluteString, "smb://nas/photos")
    }

    func testEachProtocolIsKept() {
        XCTAssertEqual(parse("SMB://nas/photos")?.scheme, "smb")
        XCTAssertEqual(parse("cifs://nas/photos")?.scheme, "smb")
        XCTAssertEqual(parse("nfs://host/export/home")?.scheme, "nfs")
        XCTAssertEqual(parse("https://dav.example.com/remote.php/dav")?.scheme, "https")
        XCTAssertEqual(parse("webdav://dav.example.com/x")?.scheme, "http")
        XCTAssertEqual(parse("webdavs://dav.example.com/x")?.scheme, "https")
        XCTAssertEqual(parse("ftp://ftp.example.com")?.scheme, "ftp")
        XCTAssertEqual(parse("afp://old-mac/share")?.scheme, "afp")
    }

    func testSpacesAreEscapedAndWhatIsEscapedIsKept() {
        XCTAssertEqual(parse("smb://nas/My Photos")?.absoluteString, "smb://nas/My%20Photos")
        XCTAssertEqual(parse("smb://nas/My%20Photos")?.absoluteString, "smb://nas/My%20Photos")
        XCTAssertEqual(parse("smb://peter@nas/photos")?.user(), "peter")
    }

    func testWhatCannotBeMountedSaysWhy() {
        XCTAssertTrue(problem("sftp://host/x")?.contains("SFTP") ?? false)
        XCTAssertTrue(problem("s3://bucket")?.contains("object store") ?? false)
        XCTAssertTrue(problem("gopher://x")?.contains("smb://") ?? false)
        XCTAssertNotNil(problem(""))
        XCTAssertNotNil(problem("smb://"))
    }

    func testKindsAndShares() {
        let url = parse("smb://nas/photos/2024/june")!
        XCTAssertEqual(ServerAddress.kind(of: url), .smb)
        XCTAssertEqual(ServerAddress.share(of: url), "photos")
        XCTAssertEqual(ServerAddress.inside(url), ["2024", "june"])

        let nfs = parse("nfs://host/export/home")!
        XCTAssertNil(ServerAddress.share(of: nfs))
        XCTAssertEqual(ServerAddress.inside(nfs), [], "NFS mounts the whole path")
        XCTAssertEqual(ServerAddress.kind(of: parse("https://x/y")!), .webdav)
    }

    func testTitles() {
        XCTAssertEqual(ServerAddress.title(of: parse("smb://nas/photos")!), "photos on nas")
        XCTAssertEqual(ServerAddress.title(of: parse("smb://nas")!), "nas")
        XCTAssertEqual(ServerAddress.title(of: URL(string: "smb://NAS._smb._tcp.local/photos")!),
                       "photos on NAS")
    }

    func testAPasswordIsNeverKept() {
        let url = parse("smb://peter:secret@nas/photos")!
        XCTAssertEqual(ServerAddress.withoutPassword(url).absoluteString, "smb://peter@nas/photos")
    }

    // MARK: - Which volume is which

    func testTheSameShareOnTheSameMachine() {
        let wanted = parse("smb://nas/photos/2024")!
        XCTAssertTrue(ServerAddress.isSameMount(
            URL(string: "smb://peter@NAS._smb._tcp.local/photos")!, as: wanted))
        XCTAssertTrue(ServerAddress.isSameMount(URL(string: "smb://nas.local./Photos")!, as: wanted))
        XCTAssertFalse(ServerAddress.isSameMount(URL(string: "smb://nas/music")!, as: wanted))
        XCTAssertFalse(ServerAddress.isSameMount(URL(string: "smb://other/photos")!, as: wanted))
        XCTAssertFalse(ServerAddress.isSameMount(URL(string: "afp://nas/photos")!, as: wanted))
        XCTAssertFalse(ServerAddress.isSameMount(URL(string: "smb://nas/photos")!,
                                                 as: parse("smb://nas")!),
                       "an address without a share is not a mount of one")
    }

    func testOtherKindsCompareTheWholePath() {
        let wanted = parse("nfs://host/export/home")!
        XCTAssertTrue(ServerAddress.isSameMount(URL(string: "nfs://host/export/home/")!, as: wanted))
        XCTAssertFalse(ServerAddress.isSameMount(URL(string: "nfs://host/export")!, as: wanted))
    }

    func testAMountedShareIsFound() {
        let mounted = [
            ServerVolumes.Mounted(remount: URL(string: "smb://nas/music")!,
                                  mountPoint: URL(fileURLWithPath: "/Volumes/music")),
            ServerVolumes.Mounted(remount: URL(string: "smb://peter@nas/photos")!,
                                  mountPoint: URL(fileURLWithPath: "/Volumes/photos-1")),
        ]
        XCTAssertEqual(ServerVolumes.mountPoint(of: parse("nas/photos")!, among: mounted)?.path,
                       "/Volumes/photos-1")
        XCTAssertNil(ServerVolumes.mountPoint(of: parse("nas/films")!, among: mounted))
    }

    func testFailuresInWords() {
        let url = parse("smb://nas/photos")!
        XCTAssertTrue(ServerMounter.problem(ENOENT, url).message.contains("\u{201C}photos\u{201D}"))
        XCTAssertTrue(ServerMounter.problem(EHOSTUNREACH, url).message.contains("cannot be reached"))
        XCTAssertTrue(ServerMounter.problem(EAUTH, url).message.contains("password"))
        XCTAssertTrue(ServerMounter.problem(-5999, url).message.contains("-5999"))
        XCTAssertTrue(ServerMounter.isCancel(ECANCELED))
        XCTAssertTrue(ServerMounter.isCancel(-128))
    }

    // MARK: - Found on the network

    func testAFoundServerBecomesAnAddressAsTypedByHand() {
        func address(_ type: String, _ host: String, _ port: UInt16, _ path: String? = nil) -> String? {
            ServerBrowser.address(kind: type, host: host, port: port, path: path)?.absoluteString
        }
        XCTAssertEqual(address("_smb._tcp", "nas.local.", 445), "smb://nas.local")
        XCTAssertEqual(address("_smb._tcp", "nas.local.", 1445), "smb://nas.local:1445")
        XCTAssertEqual(address("_afpovertcp._tcp", "old-mac.local.", 548), "afp://old-mac.local")
        XCTAssertEqual(address("_webdavs._tcp", "dav.local.", 443, "/remote.php/dav"),
                       "https://dav.local/remote.php/dav")
        XCTAssertEqual(address("_webdav._tcp", "dav.local.", 8080, "files"), "http://dav.local:8080/files")
        XCTAssertEqual(address("_nfs._tcp", "host.local.", 2049, "/export"), "nfs://host.local/export")
        XCTAssertEqual(address("_ftp._tcp", "ftp.local.", 21, "/"), "ftp://ftp.local")
        XCTAssertNil(address("_http._tcp", "x.local.", 80))
    }

    func testEveryTypeLookedForIsOneThatCanBeMounted() {
        for (type, kind) in ServerBrowser.kinds {
            let url = ServerBrowser.address(kind: type, host: "h.local.", port: 1, path: nil)
            XCTAssertEqual(url.flatMap(ServerAddress.kind(of:)), kind, type)
            XCTAssertNotNil(url.flatMap { try? ServerAddress.parse($0.absoluteString).get() }, type)
        }
    }

    // MARK: - Kept between runs

    private var file: URL!

    override func setUp() async throws {
        file = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("DiptychServers-\(UUID().uuidString)/servers.json")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
    }

    func testUsedServersAreKeptMostRecentFirstWithoutPasswords() throws {
        let store = ServerStore(file: file)
        store.used(parse("smb://peter:secret@nas/photos")!, mountPoint: URL(fileURLWithPath: "/Volumes/photos"))
        store.used(parse("nfs://host/export")!, mountPoint: nil)

        let again = ServerStore(file: file)
        XCTAssertEqual(again.servers.map(\.address), ["nfs://host/export", "smb://peter@nas/photos"])
        XCTAssertEqual(again.servers.last?.mountPoint, "/Volumes/photos")
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(text.contains("secret"))
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions]
        XCTAssertEqual((mode as? NSNumber)?.intValue, 0o600)
    }

    func testSavedComeFirstAndOpenAtLoginSavesToo() {
        let store = ServerStore(file: file)
        store.used(parse("smb://a/x")!, mountPoint: nil)
        store.used(parse("smb://b/y")!, mountPoint: nil)
        store.setSaved(store.server(for: parse("smb://a/x")!)!, true)
        XCTAssertEqual(store.servers.map(\.address), ["smb://a/x", "smb://b/y"])
        XCTAssertEqual(store.saved.count, 1)

        store.setOpenAtLogin(store.server(for: parse("smb://b/y")!)!, true)
        XCTAssertEqual(store.saved.count, 2)
        store.setSaved(store.server(for: parse("smb://b/y")!)!, false)
        XCTAssertFalse(store.server(for: parse("smb://b/y")!)!.openAtLogin,
                       "what is not kept cannot open at login")
    }

    func testOnlySoManyRecentOnesAreRemembered() {
        let store = ServerStore(file: file)
        store.used(parse("smb://kept/x")!, mountPoint: nil)
        store.setSaved(store.servers[0], true)
        for i in 0..<(ServerStore.recentLimit + 3) {
            store.used(parse("smb://host\(i)/x")!, mountPoint: nil)
        }
        XCTAssertEqual(store.recent.count, ServerStore.recentLimit)
        XCTAssertEqual(store.saved.map(\.address), ["smb://kept/x"])
        XCTAssertNil(store.server(for: parse("smb://host0/x")!), "the oldest went")
    }

    func testAVolumeMountedElsewhereIsNoticedNotPromoted() {
        let store = ServerStore(file: file)
        store.used(parse("smb://a/x")!, mountPoint: nil)
        store.noticed(URL(string: "smb://b/y")!, mountPoint: URL(fileURLWithPath: "/Volumes/y"))
        XCTAssertEqual(store.servers.first?.address, "smb://a/x")
        XCTAssertEqual(store.server(mountedAbove: "/Volumes/y/deep/down")?.1, "/Volumes/y")
        XCTAssertNil(store.server(mountedAbove: "/Volumes/yy"))
    }

    func testAForgottenServerIsGone() {
        let store = ServerStore(file: file)
        store.used(parse("smb://a/x")!, mountPoint: nil)
        store.forget(store.servers[0])
        XCTAssertTrue(ServerStore(file: file).servers.isEmpty)
    }
}
