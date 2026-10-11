import XCTest
@testable import Diptych

@MainActor
final class ManualOrderTests: XCTestCase {

    // MARK: - Where new rows go

    private func arranged(_ order: String, moved: String = "", sorted: String) -> String {
        ManualOrder(order: order.map(String.init), moved: Set(moved.map(String.init)))
            .arrange(sorted.map(String.init)).joined()
    }

    func testRowsThatAreGoneAreLeftOut() {
        XCTAssertEqual(arranged("cab", sorted: "ab"), "ab")
        XCTAssertEqual(arranged("cab", moved: "c", sorted: "abc"), "cab")
        XCTAssertEqual(arranged("cab", moved: "c", sorted: "bc"), "cb")
    }

    /// The sort puts N between P and S, neither of them moved: P N S.
    func testANewRowGoesBetweenTheUnmovedRowsAroundIt() {
        // e was moved to the top; c arrives between b and d.
        XCTAssertEqual(arranged("eabd", moved: "e", sorted: "abcde"), "eabcd")
    }

    /// After the last unmoved row the sort puts before it, even where a moved
    /// row now sits between that row and the next.
    func testANewRowFollowsTheLastUnmovedRowBeforeIt() {
        // a was moved down past b; c sorts after b.
        XCTAssertEqual(arranged("bad", moved: "a", sorted: "abcd"), "bcad")
        // b was moved down past d; c sorts after b, which moved, so after a.
        XCTAssertEqual(arranged("adb", moved: "b", sorted: "abcd"), "acdb")
    }

    /// Several new rows by one unmoved row keep the sort's order between them.
    func testNewRowsByOneRowKeepTheSortsOrder() {
        XCTAssertEqual(arranged("ae", moved: "", sorted: "abcde"), "abcde")
        XCTAssertEqual(arranged("ea", moved: "e", sorted: "abcde"), "eabcd")
    }

    /// With no unmoved row before it, before the first unmoved row after it.
    func testANewRowWithNothingBeforeItGoesBeforeTheFirstUnmovedRow() {
        // c was moved to the top; a and b sort before every other row.
        XCTAssertEqual(arranged("cde", moved: "c", sorted: "abcde"), "cabde")
    }

    /// With no unmoved row at all, at the end.
    func testWithEveryRowMovedNewRowsGoLast() {
        XCTAssertEqual(arranged("ba", moved: "ab", sorted: "abc"), "bac")
    }

    // MARK: - The pane

    private var root: URL!
    private let fm = FileManager.default

    override func setUp() async throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("DiptychManualOrder-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? fm.removeItem(at: root)
    }

    private func file(_ name: String) throws {
        try Data().write(to: root.appendingPathComponent(name))
    }

    private func names(_ pane: PaneModel) -> [String] {
        pane.rows.filter { !$0.isParent }.map(\.name)
    }

    private func select(_ names: String..., in pane: PaneModel) {
        pane.selection = Set(pane.rows.filter { names.contains($0.name) }.map(\.id))
    }

    func testShiftCommandArrowsMoveTheSelectedFile() async throws {
        for name in ["a", "b", "c", "d"] { try file(name) }
        let pane = PaneModel(directory: root)
        await pane.reloadAndWait()
        XCTAssertEqual(names(pane), ["a", "b", "c", "d"])

        select("c", in: pane)
        XCTAssertTrue(pane.moveSelectionManually(up: true))
        XCTAssertEqual(names(pane), ["a", "c", "b", "d"])
        XCTAssertTrue(pane.moveSelectionManually(up: true))
        XCTAssertEqual(names(pane), ["c", "a", "b", "d"])
        XCTAssertFalse(pane.moveSelectionManually(up: true), "the top row goes no higher")
        XCTAssertEqual(names(pane), ["c", "a", "b", "d"])
        XCTAssertNotNil(pane.manualOrder)

        // Two at once, as a block.
        select("a", "b", in: pane)
        XCTAssertTrue(pane.moveSelectionManually(up: false))
        XCTAssertEqual(names(pane), ["c", "d", "a", "b"])
    }

    func testANewFileGoesWhereTheSortWouldPutIt() async throws {
        for name in ["a", "b", "d", "e"] { try file(name) }
        let pane = PaneModel(directory: root)
        await pane.reloadAndWait()
        select("e", in: pane)
        for _ in 0..<4 { _ = pane.moveSelectionManually(up: true) }
        XCTAssertEqual(names(pane), ["e", "a", "b", "d"])

        try file("c")
        try fm.removeItem(at: root.appendingPathComponent("a"))
        await pane.reloadAndWait()
        XCTAssertEqual(names(pane), ["e", "b", "c", "d"], "c between b and d; a gone")
    }

    func testSortingOrLeavingForgetsTheOrder() async throws {
        for name in ["a", "b"] { try file(name) }
        let pane = PaneModel(directory: root)
        await pane.reloadAndWait()
        let sort = pane.sortOrder
        select("b", in: pane)
        XCTAssertTrue(pane.moveSelectionManually(up: true))
        XCTAssertEqual(names(pane), ["b", "a"])

        pane.sort(by: sort)
        XCTAssertNil(pane.manualOrder)
        XCTAssertEqual(names(pane), ["a", "b"])

        XCTAssertTrue(pane.moveSelectionManually(up: true))
        pane.navigate(to: root)
        await pane.reloadAndWait()
        XCTAssertNil(pane.manualOrder, "going to a folder, even this one, starts sorted")
    }
}
