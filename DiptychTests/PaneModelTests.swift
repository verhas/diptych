import XCTest
@testable import Diptych

@MainActor
final class PaneModelTests: XCTestCase {

    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("DiptychPaneTests-\(UUID().uuidString)")
        try fm.createDirectory(at: root.appendingPathComponent("child/grandchild"),
                               withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    private func canonical(_ url: URL) -> String {
        FileOperations.canonicalPath(url)
    }

    /// goUp() used to assign `directory` directly, so moving up was recorded
    /// neither in the pane's history nor in the saved session.
    func testGoingUpIsRecordedInHistory() throws {
        let start = root.appendingPathComponent("child/grandchild")
        let pane = PaneModel(directory: start)

        XCTAssertFalse(pane.canGoBack, "a fresh pane has nowhere to go back to")

        pane.goUp()
        XCTAssertEqual(canonical(pane.directory), canonical(root.appendingPathComponent("child")))
        XCTAssertTrue(pane.canGoBack, "going up is a navigation and belongs in the history")

        pane.goBack()
        XCTAssertEqual(canonical(pane.directory), canonical(start))
        XCTAssertTrue(pane.canGoForward)

        pane.goForward()
        XCTAssertEqual(canonical(pane.directory), canonical(root.appendingPathComponent("child")))
    }

    func testGoingSomewhereNewDiscardsTheForwardTrail() throws {
        let pane = PaneModel(directory: root.appendingPathComponent("child/grandchild"))
        pane.goUp()
        pane.goBack()
        XCTAssertTrue(pane.canGoForward)

        pane.navigate(to: root)
        XCTAssertFalse(pane.canGoForward, "a new destination replaces the forward trail")
        XCTAssertTrue(pane.canGoBack)
    }

    func testFilterMatchingFollowsGlobThenRegex() throws {
        let pane = PaneModel(directory: root)
        let text = FileItem(isParent: false, url: root.appendingPathComponent("notes.txt"),
                            name: "notes.txt", isDirectory: false, isPackage: false,
                            isSymlink: false, isExecutable: false, byteSize: 0, modified: .now)
        let markdown = FileItem(isParent: false, url: root.appendingPathComponent("readme.md"),
                                name: "readme.md", isDirectory: false, isPackage: false,
                                isSymlink: false, isExecutable: false, byteSize: 0, modified: .now)

        pane.filterText = "*.txt"
        XCTAssertTrue(pane.matchesFilter(text))
        XCTAssertFalse(pane.matchesFilter(markdown))

        pane.filterIsRegex = true
        pane.filterText = #".*\.txt"#
        XCTAssertTrue(pane.matchesFilter(text))
        XCTAssertFalse(pane.matchesFilter(markdown))

        // Anchored, so a fragment does not match the way a search would.
        pane.filterText = "txt"
        XCTAssertFalse(pane.matchesFilter(text))

        pane.filterText = "[unclosed"
        XCTAssertFalse(pane.filterIsValid)
    }

    // MARK: - Slow directories

    @MainActor
    func testNavigatingClearsTheOldListingImmediately() async throws {
        // The pane must never show one directory while claiming to be in
        // another: a double-click against the stale rows opened whatever
        // happened to sit at that row index in the new directory.
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }

        let pane = PaneModel(directory: root)
        pane.reload()
        while pane.isLoading { await Task.yield() }
        XCTAssertFalse(pane.items.isEmpty)
        pane.selection = [pane.items.last!.id]

        pane.navigate(to: root.appendingPathComponent("sub"))

        XCTAssertTrue(pane.items.isEmpty, "the old rows go at once")
        XCTAssertTrue(pane.selection.isEmpty, "and nothing stays selected")
        XCTAssertTrue(pane.isNavigating)
        XCTAssertEqual(pane.loadingDirectory?.lastPathComponent, "sub")
    }

    @MainActor
    func testRefreshingInPlaceKeepsTheRowsOnScreen() async throws {
        // A refresh is not a navigation. Clearing here would make the pane
        // blink every time a watched directory changed.
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }

        let pane = PaneModel(directory: root)
        pane.reload()
        while pane.isLoading { await Task.yield() }
        let before = pane.items.count

        pane.reload()

        XCTAssertEqual(pane.items.count, before)
        XCTAssertFalse(pane.isNavigating, "and no spinner for a refresh")
    }

    @MainActor
    func testCancellingALoadGoesBackWhereItCameFrom() async throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }

        let pane = PaneModel(directory: root)
        pane.reload()
        while pane.isLoading { await Task.yield() }

        pane.navigate(to: root.appendingPathComponent("sub"))
        XCTAssertTrue(pane.isNavigating)
        pane.cancelLoad()
        while pane.isLoading { await Task.yield() }

        XCTAssertEqual(pane.directory, root, "back where it started")
        XCTAssertFalse(pane.isNavigating)
        XCTAssertFalse(pane.items.isEmpty, "with its listing restored")
    }

    @MainActor
    func testCancellingIsNotRecordedAsSomewhereYouHaveBeen() async throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }

        let pane = PaneModel(directory: root)
        pane.reload()
        while pane.isLoading { await Task.yield() }
        let couldGoBack = pane.canGoBack

        pane.navigate(to: root.appendingPathComponent("sub"))
        pane.cancelLoad()
        while pane.isLoading { await Task.yield() }

        XCTAssertEqual(pane.canGoBack, couldGoBack,
                       "an abandoned journey is not history")
    }

    @MainActor
    func testCancellingWithNothingLoadingDoesNothing() async throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }

        let pane = PaneModel(directory: root)
        pane.reload()
        while pane.isLoading { await Task.yield() }

        pane.cancelLoad()

        XCTAssertEqual(pane.directory, root)
    }

    /// A directory with a few files and a subdirectory.
    private func makeTree() throws -> URL {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("DiptychPane-\(UUID().uuidString)")
        try fm.createDirectory(at: root.appendingPathComponent("sub"),
                               withIntermediateDirectories: true)
        for name in ["a.txt", "b.txt"] {
            try Data("x".utf8).write(to: root.appendingPathComponent(name))
        }
        try Data("x".utf8).write(to: root.appendingPathComponent("sub/c.txt"))
        return root
    }
}

extension PaneModelTests {

    /// Reported: renaming a folder lost the selection, renaming a file kept
    /// it, and renaming a folder to its own name kept it too -- because that
    /// path returns before any reload happens.
    ///
    /// The row's URL comes from the directory listing and carries a trailing
    /// slash on a folder. A URL built by the caller only gets one if the folder
    /// already existed when it was built, and a rename builds its target while
    /// the new name does not yet exist. The two never compared equal.
    func testAFolderStaysSelectedWhenItsURLHasNoTrailingSlash() async throws {
        let pane = PaneModel(directory: root)
        await pane.reloadAndWait()
        let row = try XCTUnwrap(pane.rows.first { $0.name == "child" })
        XCTAssertTrue(row.id.absoluteString.hasSuffix("/"), "the listing puts one on")

        // Exactly the shape a rename or a New Folder hands over.
        let built = URL(fileURLWithPath: row.id.path, isDirectory: false)
        XCTAssertFalse(built.absoluteString.hasSuffix("/"), "and the caller's does not")

        pane.pendingSelection = [built]
        await pane.reloadAndWait()

        XCTAssertEqual(pane.selection, [row.id], "selected all the same")
    }

    func testAFileStaysSelectedToo() async throws {
        try Data("x".utf8).write(to: root.appendingPathComponent("note.txt"))
        let pane = PaneModel(directory: root)
        await pane.reloadAndWait()
        let row = try XCTUnwrap(pane.rows.first { $0.name == "note.txt" })

        pane.pendingSelection = [URL(fileURLWithPath: row.id.path)]
        await pane.reloadAndWait()

        XCTAssertEqual(pane.selection, [row.id])
    }

    func testAPendingSelectionThatIsNotThereLeavesTheSelectionAlone() async throws {
        let pane = PaneModel(directory: root)
        await pane.reloadAndWait()
        let row = try XCTUnwrap(pane.rows.first { $0.name == "child" })
        pane.selection = [row.id]

        pane.pendingSelection = [URL(fileURLWithPath: row.id.path + "-gone")]
        await pane.reloadAndWait()

        XCTAssertEqual(pane.selection, [row.id],
                       "a target that never arrived does not clear what was there")
    }
}
