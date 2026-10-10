import XCTest
@testable import Diptych

@MainActor
final class DirectorySizesTests: XCTestCase {

    private var root: URL!
    private let fm = FileManager.default

    override func setUp() async throws {
        // By its real path, /private/var, as a pane lists it.
        let made = fm.temporaryDirectory.appendingPathComponent("DirectorySizesTests-\(UUID().uuidString)")
        try fm.createDirectory(at: made, withIntermediateDirectories: true)
        root = URL(fileURLWithPath: realpath(made.path, nil).map { String(cString: $0) } ?? made.path)
    }

    override func tearDown() async throws {
        try? fm.removeItem(at: root)
    }

    private func file(_ path: String, _ bytes: Int) throws {
        let url = root.appendingPathComponent(path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: bytes).write(to: url)
    }

    private func folder(_ path: String) -> String { root.appendingPathComponent(path).path }

    /// Asked, and waited for.
    private func calculate(_ paths: String...) async throws {
        let store = DirectorySizes.shared.store
        store.calculate(paths.map(folder))
        let deadline = Date() + 10
        while store.isWorking {
            guard Date() < deadline else { return XCTFail("never finished") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func size(_ path: String) -> Int64? { DirectorySizes.shared.store.size(folder(path)) }
    private func shown(_ path: String) -> DirectorySizes.Shown? {
        DirectorySizes.shared.store.shown(folder(path))
    }

    /// A
    /// ├── a 100
    /// └── B
    ///     ├── b 200
    ///     └── C
    ///         └── c 300
    private func tree() throws {
        try file("A/a", 100)
        try file("A/B/b", 200)
        try file("A/B/C/c", 300)
    }

    func testEverythingUnderIsCounted() async throws {
        try tree()
        try fm.createSymbolicLink(atPath: folder("A/link"), withDestinationPath: "/usr")
        try await calculate("A")
        XCTAssertEqual(size("A"), 600, "the link is not followed")
        XCTAssertEqual(size("A/B"), 500)
        XCTAssertEqual(size("A/B/C"), 300)
        XCTAssertEqual(shown("A"), .done(600))
        XCTAssertNil(shown("A/a"), "a file is not a folder")
    }

    func testAFolderReadAgainCarriesTheDifferenceUp() async throws {
        try tree()
        try await calculate("A")
        try file("A/B/C/d", 50)
        try await calculate("A/B/C")
        XCTAssertEqual(size("A/B/C"), 350)
        XCTAssertEqual(size("A/B"), 550, "the folders above changed by as much")
        XCTAssertEqual(size("A"), 650)
        XCTAssertEqual(shown("A"), .done(650))
    }

    func testWhatIsKnownIsUsedThenReadAgain() async throws {
        try tree()
        try await calculate("A/B/C")
        XCTAssertEqual(size("A/B/C"), 300)
        XCTAssertNil(size("A"))
        try file("A/B/C/d", 50)
        try await calculate("A")
        XCTAssertEqual(size("A/B/C"), 350, "read again, not only used")
        XCTAssertEqual(size("A"), 650)
    }

    func testAGoneFolderIsTakenOff() async throws {
        try tree()
        try await calculate("A")
        try fm.removeItem(at: root.appendingPathComponent("A/B"))
        try await calculate("A")
        XCTAssertEqual(size("A"), 100)
        XCTAssertNil(shown("A/B"))
    }

    func testCalculationsOneAfterTheOtherCountOnce() async throws {
        try tree()
        let store = DirectorySizes.shared.store
        store.calculate([folder("A"), folder("A/B")])
        store.calculate([folder("A")])
        store.calculate([folder("A/B/C"), folder("A")])
        try await calculate("A/B")
        XCTAssertEqual(size("A"), 600)
        XCTAssertEqual(size("A/B"), 500)
        XCTAssertEqual(shown("A"), .done(600))
    }

    func testWhileWorkingTheCellsSayWhatTheyKnow() {
        XCTAssertEqual(DirectorySizes.Shown.waiting.text, "??")
        XCTAssertEqual(DirectorySizes.Shown.updating(2_000_000).text,
                       ByteCountFormatter.string(fromByteCount: 2_000_000, countStyle: .file))
        XCTAssertEqual(CellView.colour(of: .done(1)), .teal)
        XCTAssertEqual(CellView.colour(of: .updating(1)), .orange)
    }

    func testOnlyFoldersAreCalculated() {
        let item = { (name: String, directory: Bool) in
            FileItem(isParent: false, url: self.root.appendingPathComponent(name), name: name,
                     isDirectory: directory, isPackage: false, isSymlink: false,
                     isExecutable: false, byteSize: 0, modified: .distantPast)
        }
        let rows = [FileItem.parent(of: root), item("A", true), item("a.txt", false)]
        XCTAssertEqual(DirectorySizes.folders(in: rows).map(\.lastPathComponent), ["A"])
    }

    func testClearForgetsEverythingAndStopsTheWork() async throws {
        try tree()
        try await calculate("A")
        let store = DirectorySizes.shared.store
        store.calculate([folder("A")])
        store.clear()
        XCTAssertTrue(store.isEmpty)
        XCTAssertNil(shown("A"), "-- again")
        let deadline = Date() + 10
        while store.isWorking, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(store.isEmpty, "a folder read before the clear is not recorded")
        try await calculate("A")
        XCTAssertEqual(shown("A"), .done(600), "and it can be worked out again")
    }

    func testSortingBySizeTakesAFoldersTotal() async throws {
        try tree()
        try file("small/s", 1)
        try file("big.bin", 1000)
        let pane = PaneModel(directory: root)
        pane.reload()
        let deadline = Date() + 10
        while pane.items.count < 3, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        pane.sortOrder = [FileComparator(column: .size, order: .reverse)]
        try await calculate("A", "small")
        let rows = pane.rows.filter { !$0.isParent }
        XCTAssertEqual(rows.map(\.name).prefix(2), ["A", "small"], "the bigger folder first")
        var a = rows[0], small = rows[1]
        XCTAssertEqual(a.folderTotal, 600)
        a.folderTotal = 1; small.folderTotal = 2
        XCTAssertEqual(FileComparator(column: .size).compare(a, small), .orderedAscending)
    }

    // MARK: - The flat view's folders, as links

    func testAFlatRowsFoldersAndWhereTheyAre() {
        var item = FileItem(isParent: false, url: root.appendingPathComponent("a/b/x.jpg"),
                            name: "x.jpg", isDirectory: false, isPackage: false, isSymlink: false,
                            isExecutable: false, byteSize: 0, modified: .distantPast)
        item.folderPrefix = "a/b/"
        let folders = CellView.folders(of: item)
        XCTAssertEqual(folders.map(\.name), ["a", "b"])
        XCTAssertEqual(folders.map(\.url.path), [folder("a"), folder("a/b")])
    }

    // MARK: - Columns with nothing in them

    func testEmptyColumnsAreKnown() throws {
        try file("note.txt", 10)
        let rows = [
            FileItem(isParent: false, url: root.appendingPathComponent("note.txt"),
                     name: "note.txt", isDirectory: false, isPackage: false, isSymlink: false,
                     isExecutable: false, byteSize: 10, modified: .distantPast),
        ]
        let empty = ColumnArrangement.empty(in: rows, until: .distantFuture)
        XCTAssertTrue(empty.contains(.camera), "not a picture")
        XCTAssertTrue(empty.contains(.duration))
        XCTAssertFalse(empty.contains(.fileExtension))
        XCTAssertFalse(empty.contains(.owner))
        XCTAssertTrue(ColumnArrangement.empty(in: rows, until: .distantPast)
                        .isDisjoint(with: [.camera, .duration]),
                      "not known in time: not greyed")
    }

    // MARK: - The Info window's place

    func testThePlaceIsALink() {
        typealias Row = FormatDetails.Row
        let picture = FormatDetails.located(
            [FormatDetails.Section(title: "Location (GPS)",
                                   rows: [Row(name: "Latitude", value: "47.5")])],
            latitude: 47.5, longitude: 19.04)
        XCTAssertEqual(picture[0].rows.map(\.name), ["Location", "Latitude"])
        XCTAssertEqual(picture[0].rows[0].value, "47.500000, 19.040000")
        XCTAssertTrue(picture[0].rows[0].link?.absoluteString
                        .hasPrefix("https://www.google.com/maps/search/") == true)

        let video = FormatDetails.located(
            [FormatDetails.Section(title: "Written in the file",
                                   rows: [Row(name: "Location", value: "+47.5+019.04/")])],
            latitude: 47.5, longitude: 19.04)
        XCTAssertEqual(video[0].rows.count, 1)
        XCTAssertEqual(video[0].rows[0].value, "+47.5+019.04/")
        XCTAssertNotNil(video[0].rows[0].link)
    }
}
