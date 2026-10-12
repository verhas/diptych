import XCTest
@testable import Diptych

/// What changes when a folder is on a server or cannot be written to: the
/// facts a pane learns about its volume, the `._` files macOS leaves on
/// servers, and picture details read after the rows. A small read-only disk
/// image stands in for a read-only server: it needs no network.
@MainActor
final class ServerVolumeTests: XCTestCase {

    private var folder: URL!
    private let manager = FileManager.default

    override func setUp() async throws {
        folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("DiptychVolumes-\(UUID().uuidString)")
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? manager.removeItem(at: folder)
    }

    // MARK: - ._ files

    func testAppleDoubleBesideItsFileIsLeftOut() {
        let urls = ["photo.jpg", "._photo.jpg", "._orphan", "._", "notes.txt", ".hidden"]
            .map { folder.appendingPathComponent($0) }
        XCTAssertEqual(DirectoryLoader.withoutAppleDouble(urls).map(\.lastPathComponent),
                       ["photo.jpg", "._orphan", "._", "notes.txt", ".hidden"])
    }

    func testTheListingLeavesThemOutEvenWithHiddenFilesShown() throws {
        for name in ["photo.jpg", "._photo.jpg", ".hidden"] {
            try Data("x".utf8).write(to: folder.appendingPathComponent(name))
        }
        let names = try DirectoryLoader.list(directory: folder, showHidden: true, columns: [.name])
            .filter { !$0.isParent }.map(\.name)
        XCTAssertEqual(Set(names), ["photo.jpg", ".hidden"])
    }

    // MARK: - Picture details later

    func testPictureDetailsCanBeLeftForLater() throws {
        let picture = folder.appendingPathComponent("p.png")
        try XCTUnwrap(NSImage(size: NSSize(width: 4, height: 2), flipped: false) { rect in
            NSColor.red.setFill(); rect.fill(); return true
        }.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0) }?
            .representation(using: .png, properties: [:])).write(to: picture)

        let now = try DirectoryLoader.list(directory: folder, showHidden: false,
                                           columns: [.name, .dimensions])
        let later = try DirectoryLoader.list(directory: folder, showHidden: false,
                                             columns: [.name, .dimensions], deferMedia: true)
        XCTAssertNotNil(now.first { $0.name == "p.png" }?.media)
        XCTAssertNil(later.first { $0.name == "p.png" }?.media)
    }

    // MARK: - What a folder is on

    func testThisMacsOwnDiskIsLocalAndWritable() {
        let facts = VolumeFacts.of(folder)
        XCTAssertFalse(facts.isNetwork)
        XCTAssertFalse(facts.isReadOnly)
        XCTAssertNotNil(facts.typeName)
        XCTAssertNotNil(facts.name)
    }

    func testAReadOnlyVolumeIsKnownToBeOneAndThePaneLearnsIt() async throws {
        let image = folder.appendingPathComponent("ro.dmg")
        let mountPoint = folder.appendingPathComponent("mounted")
        try hdiutil(["create", "-size", "2m", "-fs", "HFS+", "-volname", "DiptychRO",
                     "-quiet", image.path])
        try hdiutil(["attach", "-readonly", "-nobrowse", "-quiet",
                     "-mountpoint", mountPoint.path, image.path])
        defer { try? hdiutil(["detach", "-quiet", "-force", mountPoint.path]) }

        let facts = VolumeFacts.of(mountPoint)
        XCTAssertTrue(facts.isReadOnly)
        XCTAssertFalse(facts.isNetwork)
        XCTAssertEqual(facts.name, "DiptychRO")

        let pane = PaneModel(directory: folder)
        XCTAssertFalse(pane.volume.isReadOnly)
        pane.navigate(to: mountPoint)
        for _ in 0..<100 where !pane.volume.isReadOnly {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(pane.volume.isReadOnly)

        pane.navigate(to: folder)
        for _ in 0..<100 where pane.volume.isReadOnly {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(pane.volume.isReadOnly, "back on a writable disk")
    }

    private func hdiutil(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "hdiutil", code: Int(process.terminationStatus))
        }
    }

    // MARK: - A server that went away

    func testAPaneWaitsForItsServerInsteadOfLeaving() async throws {
        let image = folder.appendingPathComponent("share.dmg")
        let mountPoint = folder.appendingPathComponent("share")
        try hdiutil(["create", "-size", "2m", "-fs", "HFS+", "-volname", "Share", "-quiet",
                     image.path])
        try hdiutil(["attach", "-nobrowse", "-quiet", "-mountpoint", mountPoint.path, image.path])
        var attached = true
        defer { if attached { try? hdiutil(["detach", "-quiet", "-force", mountPoint.path]) } }
        let inside = mountPoint.appendingPathComponent("photos")
        try manager.createDirectory(at: inside, withIntermediateDirectories: true)

        // As if it had been connected to, and mounted there.
        let store = ServerStore(file: folder.appendingPathComponent("servers.json"))
        store.used(URL(string: "smb://nas/share")!, mountPoint: mountPoint)

        let pane = PaneModel(directory: folder)
        pane.servers = store
        pane.navigate(to: inside)
        await pane.reloadAndWait()
        XCTAssertNil(pane.errorText)
        XCTAssertNil(pane.awaitingServer)

        // Gone from under it: the pane stays, and says which server.
        try hdiutil(["detach", "-quiet", "-force", mountPoint.path])
        attached = false
        await pane.reloadAndWait()
        XCTAssertEqual(pane.directory.path, inside.path, "not sent somewhere else")
        XCTAssertEqual(pane.awaitingServer?.address, "smb://nas/share")
        XCTAssertEqual(pane.errorText, "share on nas is not connected.")

        // Leaving it ends the wait.
        pane.navigate(to: folder)
        await pane.reloadAndWait()
        XCTAssertNil(pane.awaitingServer)
        XCTAssertNil(pane.errorText)
    }

}
