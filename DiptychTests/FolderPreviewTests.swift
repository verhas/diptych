import XCTest
@testable import Diptych

/// Space on a folder: Diptych's own panel, a tree whose folders are read when
/// they are opened.
@MainActor
final class FolderPreviewTests: XCTestCase {

    private var root: URL!
    private let fm = FileManager.default

    override func setUp() async throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("DiptychFolderPreview-\(UUID().uuidString)")
        try fm.createDirectory(at: root.appendingPathComponent("src/deep"),
                               withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("empty"),
                               withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: root.appendingPathComponent("b.txt"))
        try Data("int x;".utf8).write(to: root.appendingPathComponent("src/main.c"))
    }

    override func tearDown() async throws {
        try? fm.removeItem(at: root)
    }

    private func load(_ node: FolderNode, in tree: FolderTree) async {
        let done = expectation(description: "read \(node.name)")
        tree.loaded = { if $0 === node { done.fulfill() } }
        tree.load(node)
        await fulfillment(of: [done], timeout: 5)
    }

    func testWhatShowsAsAFolder() throws {
        XCTAssertTrue(FolderPreview.shows(root))
        XCTAssertFalse(FolderPreview.shows(root.appendingPathComponent("b.txt")))
        let app = root.appendingPathComponent("Thing.app")
        try fm.createDirectory(at: app.appendingPathComponent("Contents"),
                               withIntermediateDirectories: true)
        XCTAssertFalse(FolderPreview.shows(app), "a package is what it is, not a folder")
        let link = root.appendingPathComponent("link")
        try fm.createSymbolicLink(at: link, withDestinationURL: root.appendingPathComponent("src"))
        XCTAssertFalse(FolderPreview.shows(link), "a link has its own page")
    }

    func testFoldersAreReadWhenOpenedFoldersFirst() async throws {
        let tree = FolderTree(root: root)
        XCTAssertNil(tree.top.children)
        XCTAssertEqual(tree.top.shown.count, 1, "Reading\u{2026} until it is read")
        await load(tree.top, in: tree)
        XCTAssertEqual(tree.top.children?.map(\.name), ["empty", "src", "b.txt"])
        XCTAssertEqual(tree.summary, "1 file, 2 folders")
        let b = try XCTUnwrap(tree.top.children?.last)
        XCTAssertEqual(b.size, 5)
        XCTAssertNotNil(b.modified)
        XCTAssertEqual(b.url, root.appendingPathComponent("b.txt"))

        let src = try XCTUnwrap(tree.top.children?[1])
        XCTAssertNil(src.children, "not read before it is opened")
        await load(src, in: tree)
        XCTAssertEqual(src.children?.map(\.name), ["deep", "main.c"])
        XCTAssertEqual(src.children?[1].url, root.appendingPathComponent("src/main.c"))

        let empty = try XCTUnwrap(tree.top.children?.first)
        await load(empty, in: tree)
        XCTAssertEqual(empty.children?.count, 1)
        guard case .empty = empty.children?.first?.note else {
            return XCTFail("an empty folder says so")
        }
    }
}
