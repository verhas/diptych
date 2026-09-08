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
}
