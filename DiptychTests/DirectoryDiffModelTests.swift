import XCTest
@testable import Diptych

/// One directory-comparison window: its options, its filter, and what it
/// actually puts on screen.
@MainActor
final class DirectoryDiffModelTests: XCTestCase {

    private var root: URL!
    private var left: URL!
    private var right: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("DiptychDirDiffModel-\(UUID().uuidString)")
        left = root.appendingPathComponent("left")
        right = root.appendingPathComponent("right")
        try fm.createDirectory(at: left, withIntermediateDirectories: true)
        try fm.createDirectory(at: right, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    private func write(_ text: String, at relative: String, in base: URL) throws {
        let url = base.appendingPathComponent(relative)
        try fm.createDirectory(at: url.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Refreshing

    func testChangingAnOptionAfterLoadingAsksForARefresh() async throws {
        try write("hello", at: "a.txt", in: left)
        try write("hello", at: "a.txt", in: right)
        let model = DirectoryDiffModel(left: left, right: right)

        await model.load()
        XCTAssertFalse(model.needsRefresh)

        model.options.comparePermissions.toggle()
        XCTAssertTrue(model.needsRefresh)

        await model.load()
        XCTAssertFalse(model.needsRefresh, "loading again with the new options catches it up")
    }

    func testASelectionThatNoLongerExistsAfterARefreshIsCleared() async throws {
        try write("same bytes", at: "old.txt", in: left)
        try write("same bytes", at: "new.txt", in: right)
        let model = DirectoryDiffModel(left: left, right: right)
        await model.load()

        // Matched as a rename, under a "rename:" id.
        let renamed = try XCTUnwrap(model.pairs.first { $0.isRename })
        model.selection = renamed.id

        // With content off, a rename cannot be told from two unrelated files,
        // so that id stops existing.
        model.options.compareContent = false
        await model.load()

        XCTAssertNil(model.selection)
    }

    // MARK: - Only showing differences

    func testOnlyShowDifferencesHidesMatchingPairs() async throws {
        try write("same", at: "same.txt", in: left)
        try write("same", at: "same.txt", in: right)
        try write("only here", at: "only-left.txt", in: left)
        let model = DirectoryDiffModel(left: left, right: right)
        await model.load()

        XCTAssertEqual(model.displayedPairs.count, 2)
        model.onlyShowDifferences = true
        XCTAssertEqual(model.displayedPairs.count, 1)
        XCTAssertEqual(model.displayedPairs.first?.status, .onlyLeft)
    }

    func testSelectingAMatchingPairIsClearedWhenOnlyDifferencesIsSwitchedOn() async throws {
        try write("same", at: "same.txt", in: left)
        try write("same", at: "same.txt", in: right)
        let model = DirectoryDiffModel(left: left, right: right)
        await model.load()

        model.selection = "same.txt"
        model.onlyShowDifferences = true

        XCTAssertNil(model.selection)
    }

    // MARK: - The filter

    func testThePlainFilterFindsAFragmentInEitherSidesName() async throws {
        try write("x", at: "invoice.pdf", in: left)
        try write("x", at: "invoice.pdf", in: right)
        try write("x", at: "receipt.pdf", in: left)
        try write("x", at: "receipt.pdf", in: right)
        let model = DirectoryDiffModel(left: left, right: right)
        await model.load()

        model.filterText = "invoice"
        let invoice = try XCTUnwrap(model.pairs.first { $0.id == "invoice.pdf" })
        let receipt = try XCTUnwrap(model.pairs.first { $0.id == "receipt.pdf" })
        XCTAssertTrue(model.matchesFilter(invoice))
        XCTAssertFalse(model.matchesFilter(receipt))
    }

    func testARenameMatchesOnEitherOfItsTwoNames() async throws {
        try write("same bytes", at: "old-name.txt", in: left)
        try write("same bytes", at: "new-name.txt", in: right)
        let model = DirectoryDiffModel(left: left, right: right)
        await model.load()

        let renamed = try XCTUnwrap(model.pairs.first { $0.isRename })
        model.filterText = "old-name"
        XCTAssertTrue(model.matchesFilter(renamed))
        model.filterText = "new-name"
        XCTAssertTrue(model.matchesFilter(renamed))
        model.filterText = "nothing-like-either"
        XCTAssertFalse(model.matchesFilter(renamed))
    }

    func testHideActuallyRemovesNonMatchingRowsFromWhatIsDisplayed() async throws {
        try write("x", at: "invoice.pdf", in: left)
        try write("x", at: "invoice.pdf", in: right)
        try write("x", at: "receipt.pdf", in: left)
        try write("x", at: "receipt.pdf", in: right)
        let model = DirectoryDiffModel(left: left, right: right)
        await model.load()

        model.filterText = "invoice"
        XCTAssertEqual(model.displayedPairs.count, 2, "not hidden yet, only dimmed by the view")

        model.filterHidesOthers = true
        XCTAssertEqual(model.displayedPairs.map(\.id), ["invoice.pdf"])
    }

    func testAnInvalidRegularExpressionIsReportedRatherThanCrashing() async throws {
        try write("x", at: "a.txt", in: left)
        try write("x", at: "a.txt", in: right)
        let model = DirectoryDiffModel(left: left, right: right)
        await model.load()

        model.filterIsRegex = true
        model.filterText = "("
        XCTAssertFalse(model.filterIsValid)
        // An invalid filter matches everything rather than nothing -- the
        // same rule a pane's own filter follows.
        XCTAssertTrue(model.matchesFilter(model.pairs[0]))
    }
}
