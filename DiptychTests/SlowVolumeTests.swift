import XCTest
@testable import Diptych

/// What a slow or read-only volume shows while it is being worked on: the
/// counts while a folder or a tree is read, the rows from the last time, the
/// size and room of each volume, the reason nothing can be written, and the
/// transfers waiting their turn.
@MainActor
final class SlowVolumeTests: XCTestCase {

    private var folder: URL!
    private let manager = FileManager.default

    override func setUp() async throws {
        folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("DiptychSlow-\(UUID().uuidString)")
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        try? manager.removeItem(at: folder)
    }

    // MARK: - Reading a folder

    func testAFolderSaysHowManyItHasReadAndListsTheSame() throws {
        for i in 0..<300 { try Data().write(to: folder.appendingPathComponent("f\(i)")) }
        var heard: [Int] = []
        let listed = try DirectoryLoader.list(directory: folder, showHidden: false,
                                              columns: [.name]) { heard.append($0) }
        XCTAssertEqual(listed.filter { !$0.isParent }.count, 300)
        XCTAssertTrue(heard.allSatisfy { $0 <= 300 })
    }

    func testAFolderThatCannotBeReadSaysSoAsBefore() throws {
        let locked = folder.appendingPathComponent("locked")
        try manager.createDirectory(at: locked, withIntermediateDirectories: true)
        try manager.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        defer { try? manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }

        XCTAssertThrowsError(try DirectoryLoader.list(directory: locked, showHidden: false,
                                                      columns: [.name])) { error in
            XCTAssertEqual((error as NSError).code, NSFileReadNoPermissionError)
        }
        XCTAssertThrowsError(try DirectoryLoader.list(
            directory: folder.appendingPathComponent("missing"), showHidden: false,
            columns: [.name])) { error in
            XCTAssertEqual((error as NSError).code, NSFileReadNoSuchFileError)
        }
    }

    // MARK: - Walking a tree

    func testTheWalkReportsHowFarItHasGotWhenNothingMatches() throws {
        for d in 0..<3 {
            let sub = folder.appendingPathComponent("d\(d)")
            try manager.createDirectory(at: sub, withIntermediateDirectories: true)
            for f in 0..<5 { try Data().write(to: sub.appendingPathComponent("f\(f).txt")) }
        }
        let query = try FlatQuery.parse("directory traversed or (file and name = \"*.nothing\")").get()
        var last: FlatScanner.Progress?
        var found = 0
        FlatScanner.walk(root: folder, query: query, showHidden: false) { batch, progress in
            found += batch.count
            last = progress
        }
        XCTAssertEqual(found, 0)
        XCTAssertEqual(last?.folders, 4, "the top and three below")
        XCTAssertEqual(last?.seen, 18, "three folders, and five files in each")
    }

    // MARK: - Listed before

    func testAServerFolderListedBeforeIsKeptForNextTime() {
        let cache = ListingCache()
        let rows = [FileItem.parent(of: folder)]
        cache.keep(rows, of: folder, showHidden: false)
        XCTAssertEqual(cache.rows(of: folder, showHidden: false)?.rows.count, 1)
        XCTAssertNil(cache.rows(of: folder, showHidden: true), "hidden files make other rows")
        cache.forget(folder)
        XCTAssertNil(cache.rows(of: folder, showHidden: false))
    }

    func testOnlySoManyAreKept() {
        let cache = ListingCache()
        for i in 0...ListingCache.limit {
            cache.keep([], of: folder.appendingPathComponent("\(i)"), showHidden: false)
        }
        XCTAssertNil(cache.rows(of: folder.appendingPathComponent("0"), showHidden: false))
        XCTAssertNotNil(cache.rows(of: folder.appendingPathComponent("1"), showHidden: false))
    }

    // MARK: - How often a server is looked at

    func testTheIntervalIsReadAndKeptInBounds() throws {
        func decoded(_ json: String) throws -> Int {
            try JSONDecoder().decode(Configuration.self, from: Data(json.utf8))
                .serverRefreshSeconds
        }
        XCTAssertEqual(try decoded("{}"), 5)
        XCTAssertEqual(try decoded(#"{"serverRefreshSeconds": 0}"#), 0, "only Refresh")
        XCTAssertEqual(try decoded(#"{"serverRefreshSeconds": -3}"#), 0)
        XCTAssertEqual(try decoded(#"{"serverRefreshSeconds": 99999}"#), 3600)
    }

    // MARK: - Size and room

    func testAVolumeSaysItsSizeAndRoom() {
        let entry = SidebarEntry(kind: .volume, url: URL(fileURLWithPath: "/Volumes/x"),
                                 name: "x", capacity: 2_000_000_000_000,
                                 available: 340_000_000_000)
        XCTAssertEqual(entry.spaceText, "2 TB, 340 GB free")
        XCTAssertNil(SidebarEntry(kind: .favourite, url: folder, name: "f").spaceText)
    }

    // MARK: - Read-only volumes

    func testAReadOnlyVolumeIsNamedAsTheReasonAndTheBinaryViewTakesNoEdits() async throws {
        let image = folder.appendingPathComponent("ro.dmg")
        let mountPoint = folder.appendingPathComponent("mounted")
        try hdiutil(["create", "-size", "2m", "-fs", "HFS+", "-volname", "DiptychRO",
                     "-quiet", image.path])
        // Written to once, then attached again read-only.
        try hdiutil(["attach", "-nobrowse", "-quiet", "-mountpoint", mountPoint.path, image.path])
        try Data([1, 2, 3, 4]).write(to: mountPoint.appendingPathComponent("data.bin"))
        try hdiutil(["detach", "-quiet", mountPoint.path])
        try hdiutil(["attach", "-readonly", "-nobrowse", "-quiet",
                     "-mountpoint", mountPoint.path, image.path])
        defer { try? hdiutil(["detach", "-quiet", "-force", mountPoint.path]) }
        let file = mountPoint.appendingPathComponent("data.bin")

        XCTAssertEqual(WriteTrouble.readOnlyVolume(of: file), "\u{201C}DiptychRO\u{201D}")
        XCTAssertNil(WriteTrouble.readOnlyVolume(of: folder))
        let said = WriteTrouble.explaining(CocoaError(.fileWriteNoPermission), writing: file)
        XCTAssertTrue(said.contains("mounted read-only"), said)

        let binary = BinaryViewModel(url: file)
        for _ in 0..<200 where binary.isLoading { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(binary.readOnlyVolume, "\u{201C}DiptychRO\u{201D}")
        binary.type("f")
        binary.type("f")
        XCTAssertFalse(binary.hasEdits)
        XCTAssertTrue(binary.statusIsError)
    }

    func testABinarySaveIsReadBack() async throws {
        let file = folder.appendingPathComponent("data.bin")
        try Data([1, 2, 3, 4]).write(to: file)
        let binary = BinaryViewModel(url: file)
        for _ in 0..<200 where binary.isLoading { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(binary.readOnlyVolume)
        binary.type("f")
        binary.type("f")
        binary.save()
        XCTAssertFalse(binary.statusIsError, binary.status ?? "")
        XCTAssertEqual(try Data(contentsOf: file), Data([0xFF, 2, 3, 4]))
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

    // MARK: - Waiting transfers

    func testAWaitingTransferSaysWhatAndWhere() {
        let one = AppModel.QueuedTransfer(kind: .copy, sources: [folder.appendingPathComponent("a.mov")],
                                              target: URL(fileURLWithPath: "/Films"))
        XCTAssertEqual(one.description, "Copy \u{201C}a.mov\u{201D} to \u{201C}Films\u{201D}")
        let many = AppModel.QueuedTransfer(kind: .move,
                                           sources: ["a", "b", "c", "d"]
                                               .map { folder.appendingPathComponent($0) },
                                           target: URL(fileURLWithPath: "/x"))
        XCTAssertEqual(many.description,
                       "Move \u{201C}a\u{201D}, \u{201C}b\u{201D} and 2 more to \u{201C}x\u{201D}")
    }

    func testAFolderDroppedOnItselfOrInsideStaysHome() {
        let photos = folder.appendingPathComponent("photos")
        XCTAssertTrue(AppModel.droppedHome(photos, into: folder), "its own folder")
        XCTAssertTrue(AppModel.droppedHome(photos, into: photos), "its own row")
        XCTAssertTrue(AppModel.droppedHome(photos, into: photos.appendingPathComponent("2024")))
        XCTAssertTrue(AppModel.droppedHome(URL(fileURLWithPath: photos.path + "/"), into: photos),
                      "a folder's URL ends in a slash")
        XCTAssertFalse(AppModel.droppedHome(photos, into: folder.appendingPathComponent("photos-old")))
        XCTAssertFalse(AppModel.droppedHome(photos, into: folder.appendingPathComponent("other")))
    }

    func testATransferAskedForAgainIsKnown() {
        let a = folder.appendingPathComponent("a")
        let films = URL(fileURLWithPath: "/Films")
        let move = AppModel.QueuedTransfer(kind: .move, sources: [a], target: films)
        XCTAssertTrue(move.covers(a, to: films, kind: .move))
        XCTAssertTrue(move.covers(a, to: URL(fileURLWithPath: "/Other"), kind: .move),
                      "it can only leave once")
        XCTAssertFalse(move.covers(folder.appendingPathComponent("b"), to: films, kind: .move))

        let copy = AppModel.QueuedTransfer(kind: .copy, sources: [a], target: films)
        XCTAssertTrue(copy.covers(a, to: films, kind: .copy))
        XCTAssertFalse(copy.covers(a, to: URL(fileURLWithPath: "/Other"), kind: .copy),
                       "a copy elsewhere is another copy")
        XCTAssertFalse(copy.covers(a, to: films, kind: .move))
    }

    func testDurationsInWords() {
        XCTAssertNil(TransferProgress.duration(0.5))
        XCTAssertEqual(TransferProgress.duration(42), "42 seconds")
        XCTAssertEqual(TransferProgress.duration(250), "4 minutes, 10 seconds")
        XCTAssertEqual(TransferProgress.duration(3 * 3600 + 120), "3 hours, 2 minutes")
        XCTAssertNil(TransferProgress.duration(2 * 86400))
    }
}
